# MDEHuntScheduler Function App

using namespace System.Net

param($Timer)

function Get-HuntSchedules {
    param (
        [Parameter(Mandatory = $false)]
        [bool]$EnabledOnly = $true
    )
    
    try {
        Write-Host "Starting Get-HuntSchedules"
        
        # Get storage account name from environment
        $storageAccountName = [System.Environment]::GetEnvironmentVariable('STORAGE_ACCOUNT', 'Process')
        if ([string]::IsNullOrEmpty($storageAccountName)) {
            throw "STORAGE_ACCOUNT environment variable is required"
        }
        
        # Create context for AzBobbyTables
        try {
            $connectionString = [System.Environment]::GetEnvironmentVariable('WEBSITE_AZUREFILESCONNECTIONSTRING', 'Process')
            $context = New-AzDataTableContext -TableName "HuntSchedules" -ConnectionString $connectionString
        } catch {
            Write-Host "Failed to create context: $($_.Exception.Message)"
            throw "Unable to create storage context: $($_.Exception.Message)"
        }
        
        # Build filter based on parameters
        $filter = "PartitionKey eq 'HuntSchedule'"
        
        if ($EnabledOnly) {
            $filter += " and Enabled eq true"
        }
        
        # Get hunt schedule entities from the table
        $entities = Get-AzDataTableEntity -Context $context -Filter $filter -ErrorAction SilentlyContinue
        
        if (-not $entities) {
            return @{
                Status = "Success"
                Message = "No hunt schedules found in storage table"
                Schedules = @()
                Count = 0
                Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
            }
        }
        
        # Convert entities to a clean array of schedule information
        $scheduleList = @()
        foreach ($entity in $entities) {
            try {
                # Deserialize the hunt schedule JSON back to object
                $huntScheduleObj = $entity.HuntSchedule | ConvertFrom-Json
                  $scheduleInfo = @{
                    ScheduleId = $entity.RowKey
                    ScheduleTime = $huntScheduleObj.ScheduleTime
                    ScheduleName = $huntScheduleObj.ScheduleName
                    TenantId = $entity.TenantId
                    ClientName = $entity.ClientName
                    HuntSchedule = $huntScheduleObj
                    Enabled = $entity.Enabled
                    CreatedDate = $entity.CreatedDate
                    CreatedBy = $entity.CreatedBy
                }
                $scheduleList += $scheduleInfo
            } catch {
                Write-Warning "Failed to parse hunt schedule for entity $($entity.RowKey): $($_.Exception.Message)"
                continue
            }
        }
        
        Write-Host "Retrieved $($scheduleList.Count) hunt schedules successfully"
        
        return @{
            Status = "Success"
            Message = "Retrieved $($scheduleList.Count) hunt schedule(s) from storage table"
            Schedules = $scheduleList
            Count = $scheduleList.Count
            Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
        
    } catch {
        $errorMessage = "Failed to retrieve hunt schedules: $($_.Exception.Message)"
        Write-Error $errorMessage
        return @{
            Status = "Error"
            Message = $errorMessage
            Schedules = @()
            Count = 0
            Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    }
}

try {
    Write-Host "MDEHuntScheduler timer trigger started at $(Get-Date)"
    
    # Get current time in UTC
    $currentTimeString = $currentTime.ToString("HH:mm")
    Write-Host "Current UTC time: $currentTimeString"
    
    # Calculate the time window for the last hour
    $oneHourAgo = $currentTime.AddHours(-1)
    $oneHourAgoString = $oneHourAgo.ToString("HH:mm")
    Write-Host "Looking for schedules between $oneHourAgoString and $currentTimeString"
    
    # Get hunt schedules from storage table
    Write-Host "Retrieving hunt schedules from Azure Storage Table 'HuntSchedules'"
    $schedulesResponse = Get-HuntSchedules -EnabledOnly $true
    
    if ($schedulesResponse.Status -ne "Success" -or $schedulesResponse.Count -eq 0) {
        Write-Host "No enabled hunt schedules found: $($schedulesResponse.Message)"
        return
    }
    
    Write-Host "Found $($schedulesResponse.Count) enabled hunt schedules"
    
    # Filter schedules that should have run in the last hour
    $schedulesToRun = @()
    foreach ($schedule in $schedulesResponse.Schedules) {
        # Check if schedule has ScheduleTime property (either in entity or HuntSchedule object)
        $scheduleTime = $null
        if ($schedule.ScheduleTime) {
            $scheduleTime = $schedule.ScheduleTime
        } elseif ($schedule.HuntSchedule.ScheduleTime) {
            $scheduleTime = $schedule.HuntSchedule.ScheduleTime
        }
        
        if ($scheduleTime) {
            try {
                # Parse the schedule time (assuming format like "14:30" or "14:30:00")
                $scheduledDateTime = [DateTime]::ParseExact($scheduleTime, "HH:mm", $null)
                $scheduledTime = $scheduledDateTime.TimeOfDay
                $currentTimeOfDay = $currentTime.TimeOfDay
                $oneHourAgoTimeOfDay = $oneHourAgo.TimeOfDay
                
                # Check if the scheduled time falls within the last hour
                $shouldRun = $false
                if ($oneHourAgoTimeOfDay -le $currentTimeOfDay) {
                    # Normal case: not crossing midnight
                    $shouldRun = ($scheduledTime -gt $oneHourAgoTimeOfDay -and $scheduledTime -le $currentTimeOfDay)
                } else {
                    # Crossing midnight case
                    $shouldRun = ($scheduledTime -gt $oneHourAgoTimeOfDay -or $scheduledTime -le $currentTimeOfDay)
                }
                
                if ($shouldRun) {
                    $schedulesToRun += $schedule
                    Write-Host "Schedule '$($schedule.ScheduleId)' (time: $scheduleTime) should run"
                }
            } catch {
                Write-Host "Warning: Could not parse schedule time '$scheduleTime' for schedule '$($schedule.ScheduleId)': $($_.Exception.Message)"
            }
        } else {
            Write-Host "Warning: No ScheduleTime found for schedule '$($schedule.ScheduleId)'"
        }
    }
    
    if ($schedulesToRun.Count -eq 0) {
        Write-Host "No hunt schedules configured to run in the last hour ($oneHourAgoString - $currentTimeString)"
        return
    }
    
    Write-Host "Found $($schedulesToRun.Count) schedules that should run in the last hour"
    
    # Get storage account name from environment  
    $storageAccountName = [System.Environment]::GetEnvironmentVariable('STORAGE_ACCOUNT', 'Process')
    $containerName = "huntquery"
    
    # Create storage context using User Managed Identity
    try {
        $ctx = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount
        Write-Host "Storage context created successfully for blob operations using UMI"
    } catch {
        Write-Host "Failed to create storage context with UMI: $($_.Exception.Message)"
        return
    }
    $functionUrl = [System.Environment]::GetEnvironmentVariable('WEBSITE_HOSTNAME', 'Process')
      $results = @()
    
    # Process each schedule that should run in the last hour
    foreach ($schedule in $schedulesToRun) {
        Write-Host "Processing schedule ID: $($schedule.ScheduleId) for tenant: $($schedule.TenantId) ($($schedule.ClientName))"
        
        try {

            $huntQueries = @()
            $localTemp = [System.IO.Path]::GetTempPath()
            
            foreach ($queryName in $schedule.HuntSchedule.QueryNames) {
                $possibleNames = @(
                    "$queryName.kql",
                    "$queryName.csl",
                    $queryName  
                )
                
                $foundBlob = $null
                foreach ($fileName in $possibleNames) {
                    try {
                        $blob = Get-AzStorageBlob -Container $containerName -Context $ctx -Blob $fileName -ErrorAction SilentlyContinue
                        if ($blob) {
                            $foundBlob = $blob
                            Write-Host "Found query file: $fileName"
                            break
                        }
                    } catch {
                    }
                }
                
                if ($foundBlob) {
                    $localFile = Join-Path $localTemp $foundBlob.Name
                    try {
                        Get-AzStorageBlobContent -Blob $foundBlob.Name -Container $containerName -Destination $localFile -Context $ctx -Force | Out-Null
                        $queryContent = Get-Content -Path $localFile -Raw
                        if (-not [string]::IsNullOrWhiteSpace($queryContent)) {
                            $huntQueries += $queryContent.Trim()
                            Write-Host "Loaded query: $queryName"
                        }
                    } catch {
                        Write-Host "Error reading query file: $($foundBlob.Name). Error: $_"
                    } finally {
                        if (Test-Path $localFile) {
                            Remove-Item $localFile -Force -ErrorAction SilentlyContinue
                        }
                    }
                } else {
                    Write-Host "Warning: Query file not found for '$queryName'. Tried: $($possibleNames -join ', ')"
                }
            }
            
            if ($huntQueries.Count -eq 0) {
                Write-Host "No valid hunt queries loaded for schedule: $($schedule.ScheduleId)"
                continue
            }
            
            Write-Host "Loaded $($huntQueries.Count) queries for schedule: $($schedule.ScheduleId)"
            
            # Prepare payload for MDEAutoHunt
            $payload = @{
                TenantId = $schedule.TenantId
                Queries = $huntQueries
            }
            $body = $payload | ConvertTo-Json -Depth 10
            $uri = "https://$functionUrl/api/MDEAutoHunt"
            
            # Use UMI authentication for secure internal calls
            $headers = @{
                'Content-Type' = 'application/json'
            }
              # Get access token using Azure PowerShell
            $tokenInfo = Get-AzAccessToken -ResourceUrl "https://management.azure.com/" -ErrorAction Stop
            $headers['Authorization'] = "Bearer $($tokenInfo.Token)"
            Write-Host "Using Azure PowerShell authentication for Schedule: $($schedule.ScheduleId)"
            
            # Call MDEAutoHunt function
            $response = Invoke-RestMethod -Uri $uri -Method POST -Body $body -Headers $headers -ErrorAction Stop
            
            $results += [PSCustomObject]@{
                ScheduleId = $schedule.ScheduleId
                TenantId = $schedule.TenantId
                ClientName = $schedule.ClientName
                Status = "Success"
                QueriesExecuted = $huntQueries.Count
                QueryNames = $schedule.HuntSchedule.QueryNames
                Response = $response
                Timestamp = Get-Date
            }

            Write-Host "Successfully executed $($huntQueries.Count) hunt queries for schedule: $($schedule.ScheduleId) (Tenant: $($schedule.TenantId))"
            
        } catch {
            $errorDetails = $_.Exception.Message
            Write-Host "Error processing schedule '$($schedule.ScheduleId)' for tenant '$($schedule.TenantId)': $errorDetails"
            
            $results += [PSCustomObject]@{
                ScheduleId = $schedule.ScheduleId
                TenantId = $schedule.TenantId
                ClientName = $schedule.ClientName
                Status = "Failed"
                Error = $errorDetails
                Timestamp = Get-Date
            }
        }
        
        # Small delay between schedule executions
        Start-Sleep -Seconds 2
    }    # Log summary results
    $successCount = ($results | Where-Object { $_.Status -eq "Success" }).Count
    $failCount = ($results | Where-Object { $_.Status -eq "Failed" }).Count
    $totalQueries = ($results | Where-Object { $_.Status -eq "Success" } | Measure-Object -Property QueriesExecuted -Sum).Sum
    
    Write-Host "Hunt execution summary:"
    Write-Host "Time window: $oneHourAgoString - $currentTimeString UTC"
    Write-Host "Total schedules found for last hour: $($schedulesToRun.Count)"
    Write-Host "Successful executions: $successCount"
    Write-Host "Failed executions: $failCount"
    Write-Host "Total queries executed: $totalQueries"
    Write-Host "MDEHuntScheduler completed successfully at $(Get-Date)"

} catch {
    Write-Host "MDEHuntScheduler encountered an error: $_"
}

