# MDEHuntScheduler Function App
# 1.6.0

using namespace System.Net

param($Timer)

function Get-TenantIdsFromTable {    
    try {        
          Write-Host "Starting Get-TenantIdsFromTable"
        
        # Get storage account name from environment
        $storageAccountName = [System.Environment]::GetEnvironmentVariable('STORAGE_ACCOUNT', 'Process')
        if ([string]::IsNullOrEmpty($storageAccountName)) {
            throw "STORAGE_ACCOUNT environment variable is required"
        }
        
        # Create context for AzBobbyTables - prioritize connection string authentication
        try {
            Write-Host "Creating AzBobbyTables context for storage account: $storageAccountName"
            
            # Prioritize connection string from AzureWebJobsStorage
            $connectionString = [System.Environment]::GetEnvironmentVariable('WEBSITE_CONTENTAZUREFILECONNECTIONSTRING', 'Process')
            $context = New-AzDataTableContext -TableName "TenantIds" -ConnectionString $connectionString
            Write-Host "Context created successfully"
        } catch {
            Write-Host "Failed to create context: $($_.Exception.Message)"
            throw "Unable to create storage context: $($_.Exception.Message)"
        }
        # Get all tenant entities from the table using AzBobbyTables
        $entities = Get-AzDataTableEntity -Context $context -Filter "PartitionKey eq 'TenantConfig'" -ErrorAction SilentlyContinue
        
        if (-not $entities) {
            return @{
                Status = "Success"
                Message = "No tenant IDs found in storage table"
                TenantIds = @()
                Count = 0
                Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
            }
        }
        
        # Convert entities to a clean array of tenant information
        $tenantList = @()
        foreach ($entity in $entities) {
            $tenantInfo = @{
                TenantId = $entity.TenantId
                ClientName = $entity.ClientName
                Enabled = $entity.Enabled
                AddedDate = $entity.AddedDate
                AddedBy = $entity.AddedBy
            }
            $tenantList += $tenantInfo
        }
        
        Write-Host "Retrieved $($tenantList.Count) tenant IDs successfully"
        
        return @{
            Status = "Success"
            Message = "Retrieved $($tenantList.Count) tenant ID(s) from storage table"
            TenantIds = $tenantList
            Count = $tenantList.Count
            Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
        
    } catch {
        $errorMessage = "Failed to retrieve tenant IDs: $($_.Exception.Message)"
        Write-Error $errorMessage
        return @{
            Status = "Error"
            Message = $errorMessage
            TenantIds = @()
            Count = 0
            Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    }
}

try {
    Write-Host "MDEHuntScheduler timer trigger started at $(Get-Date)"
    
    # Get storage account name from environment  
    $storageAccountName = [System.Environment]::GetEnvironmentVariable('STORAGE_ACCOUNT', 'Process')
    
    # Get tenant IDs from Azure Storage Table using centralized function
    Write-Host "Retrieving tenant IDs from Azure Storage Table 'TenantIds'"
    $tenantResponse = Get-TenantIdsFromTable
    
    if ($tenantResponse.Status -ne "Success" -or $tenantResponse.Count -eq 0) {
        Write-Host "Error retrieving tenant IDs: $($tenantResponse.Message)"
        return
    }
    
    # Extract enabled tenant IDs only
    $enabledTenants = $tenantResponse.TenantIds | Where-Object { $_.Enabled -eq $true }
    if ($enabledTenants.Count -eq 0) {
        Write-Host "No enabled tenant IDs found in storage table."
        return
    }
    
    $tenantIds = $enabledTenants | ForEach-Object { $_.TenantId }
    Write-Host "Found $($tenantIds.Count) enabled tenant IDs: $($tenantIds -join ', ')"
    
    # Download hunt queries from blob storage using UMI authentication
    $containerName = "huntquery"
    
    # Create storage context using User Managed Identity
    try {
        $ctx = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount
        Write-Host "Storage context created successfully for blob operations using UMI"
    } catch {
        Write-Host "Failed to create storage context with UMI: $($_.Exception.Message)"
        return
    }
    
    $huntQueries = @()
    
    try {
        $blobs = Get-AzStorageBlob -Container $containerName -Context $ctx | Where-Object { 
            $_.Name -like '*.kql' -or $_.Name -like '*.csl' 
        }
        
        if ($blobs.Count -eq 0) {
            Write-Host "No hunt query files (.kql/.csl) found in $containerName container."
            return
        }
        
        Write-Host "Found $($blobs.Count) hunt query files in blob storage"
        
        $localTemp = [System.IO.Path]::GetTempPath()
        foreach ($blob in $blobs) {
            $localFile = Join-Path $localTemp $blob.Name
            Get-AzStorageBlobContent -Blob $blob.Name -Container $containerName -Destination $localFile -Context $ctx -Force | Out-Null
            try {
                $queryContent = Get-Content -Path $localFile -Raw
                if (-not [string]::IsNullOrWhiteSpace($queryContent)) {
                    $huntQueries += $queryContent.Trim()
                    Write-Host "Loaded query from: $($blob.Name)"
                }
            } catch {
                Write-Host "Error reading query file: $($blob.Name). Error: $_"
            } finally {
                if (Test-Path $localFile) {
                    Remove-Item $localFile -Force -ErrorAction SilentlyContinue
                }
            }
        }
    } catch {
        Write-Host "Error accessing blob storage container '$containerName': $_"
        return    }
    if ($huntQueries.Count -eq 0) {
        Write-Host "No valid hunt queries loaded from blob storage."
        return
    }    Write-Host "Successfully loaded $($huntQueries.Count) hunt queries" 
    $functionUrl = [System.Environment]::GetEnvironmentVariable('WEBSITE_HOSTNAME', 'Process')
    
    # For internal function calls, we'll use UMI authentication with the correct resource
    $managedIdentityId = [System.Environment]::GetEnvironmentVariable('AZURE_CLIENT_ID', 'Process')

    $results = @()
    foreach ($tenantId in $tenantIds) {
        Write-Host "Processing tenant: $tenantId"
        
        try {           
            $payload = @{
                TenantId = $tenantId
                Queries = $huntQueries
            }
            $body = $payload | ConvertTo-Json -Depth 10
            $uri = "https://$functionUrl/api/MDEAutoHunt"
            
            # Use UMI authentication for secure internal calls
            $headers = @{
                'Content-Type' = 'application/json'
            }         
            try {
                try {
                    
                    # Get access token using Azure PowerShell
                    $tokenInfo = Get-AzAccessToken -ResourceUrl "https://management.azure.com/" -ErrorAction Stop
                    $headers['Authorization'] = "Bearer $($tokenInfo.Token)"
                    Write-Host "Using UMI authentication via Azure PowerShell for Tenant: $tenantId"
                } catch {
                    Write-Host "Azure PowerShell approach failed, trying direct IMDS call: $($_.Exception.Message)"
                    
                    # Fallback to direct IMDS call
                    $resourceUrl = "https://management.azure.com/"
                    $tokenUrl = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$resourceUrl&client_id=$managedIdentityId"
                    $tokenResponse = Invoke-RestMethod -Uri $tokenUrl -Method GET -Headers @{ 'Metadata' = 'true' } -ErrorAction Stop
                    $headers['Authorization'] = "Bearer $($tokenResponse.access_token)"
                    Write-Host "Using UMI authentication via IMDS for Tenant: $tenantId"
                }
            } catch {
                Write-Host "Failed to get UMI token for Tenant: $tenantId - $($_.Exception.Message)"
                # Fallback: try without UMI client_id specified
                try {
                    $tokenUrl = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/"
                    $tokenResponse = Invoke-RestMethod -Uri $tokenUrl -Method GET -Headers @{ 'Metadata' = 'true' } -ErrorAction Stop
                    $headers['Authorization'] = "Bearer $($tokenResponse.access_token)"
                    Write-Host "Using system-assigned managed identity for Tenant: $tenantId"
                } catch {
                    Write-Host "Failed to get any managed identity token for Tenant: $tenantId - $($_.Exception.Message)"
                    throw "Authentication failed: Unable to get UMI or system-assigned token"
                }
            }
            
            # Call MDEAutoHunt function
            $response = Invoke-RestMethod -Uri $uri -Method POST -Body $body -Headers $headers -ErrorAction Stop
            
            $results += [PSCustomObject]@{
                TenantId = $tenantId
                Status = "Success"
                QueriesExecuted = $huntQueries.Count
                Response = $response
                Timestamp = Get-Date
            }

            Write-Host "Successfully executed $($huntQueries.Count) hunt queries for tenant: $tenantId"
            
        } catch {
            $errorDetails = $_.Exception.Message
            Write-Host "Error processing tenant '$tenantId': $errorDetails"
            
            $results += [PSCustomObject]@{
                TenantId = $tenantId
                Status = "Failed"
                Error = $errorDetails
                Timestamp = Get-Date
            }
        }        
        Start-Sleep -Seconds 2
    }

    # Log summary results
    $successCount = ($results | Where-Object { $_.Status -eq "Success" }).Count
    $failCount = ($results | Where-Object { $_.Status -eq "Failed" }).Count
    
    Write-Host "Hunt execution summary:"
    Write-Host "Total tenants processed: $($tenantIds.Count)"
    Write-Host "Successful executions: $successCount"
    Write-Host "Failed executions: $failCount"
    Write-Host "Hunt queries per tenant: $($huntQueries.Count)"
    Write-Host "MDEHuntScheduler completed successfully at $(Get-Date)"

} catch {
    Write-Host "MDEHuntScheduler encountered an error: $_"
}

