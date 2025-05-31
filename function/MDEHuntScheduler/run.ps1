# MDEHuntScheduler Function App
# 1.5.9

using namespace System.Net

param($Timer)

function Get-StorageTableContext {
    param()
    
    try {
        # Get storage account name from environment
        $storageAccountName = [System.Environment]::GetEnvironmentVariable('STORAGE_ACCOUNT', 'Process')
        
        if ([string]::IsNullOrEmpty($storageAccountName)) {
            throw "STORAGE_ACCOUNT environment variable is required"
        }
        
        # Create context for AzBobbyTables - try connection string first, then managed identity
        Write-Host "Creating AzBobbyTables context for storage account: $storageAccountName"
          # Prioritize connection string from AzureWebJobsStorage
        $connectionString = [System.Environment]::GetEnvironmentVariable('AzureWebJobsStorage', 'Process')
        
        if (-not [string]::IsNullOrEmpty($connectionString)) {
            Write-Host "Using AzureWebJobsStorage connection string authentication"
            $ctx = New-AzDataTableContext -TableName "TenantIds" -ConnectionString $connectionString -ErrorAction Stop
        } else {
            Write-Host "No connection string found, falling back to managed identity authentication"
            # Try with ClientId if available for user-assigned managed identity
            $clientId = [System.Environment]::GetEnvironmentVariable('AZURE_CLIENT_ID', 'Process')
            if (-not [string]::IsNullOrEmpty($clientId)) {
                Write-Host "Using user-assigned managed identity with ClientId: $clientId"
                $ctx = New-AzDataTableContext -TableName "TenantIds" -StorageAccountName $storageAccountName -ManagedIdentity -ClientId $clientId -ErrorAction Stop
            } else {
                Write-Host "Using system-assigned managed identity"
                $ctx = New-AzDataTableContext -TableName "TenantIds" -StorageAccountName $storageAccountName -ManagedIdentity -ErrorAction Stop
            }
        }
        
        return $ctx
        
    } catch {
        Write-Host "ERROR: Failed to create storage context: $($_.Exception.Message)"
        throw "Failed to create storage context: $($_.Exception.Message)"
    }
}

function Get-TenantIdsFromTable {
    
    try {
        Write-Host "Starting Get-TenantIdsFromTable"
        
        # Get authenticated storage context
        $ctx = Get-StorageTableContext        # Get the TenantIds table
        try {
            $table = Get-AzDataTable -Context $ctx -ErrorAction Stop
        } catch {
            return @{
                Status = "Error"
                Message = "TenantIds table not found in storage account"
                TenantIds = @()
                Count = 0
            }
        }

        # Get all tenant entities from the table using AzBobbyTables
        $entities = Get-AzDataTableEntity -Context $ctx -Filter "PartitionKey eq 'TenantConfig'" -ErrorAction SilentlyContinue
        
        if (-not $entities) {
            return @{
                Status = "Success"
                Message = "No tenant IDs found in storage table"
                TenantIds = @()
                Count = 0
            }
        }
        
        # Convert entities to a clean array of tenant information
        $tenantList = @()
        foreach ($entity in $entities) {
            $tenantInfo = @{
                TenantId = $entity.TenantId
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
        Write-Error "Error in Get-TenantIdsFromTable: $($_.Exception.Message)"
        return @{
            Status = "Error"
            Message = "Failed to retrieve tenant IDs: $($_.Exception.Message)"
            TenantIds = @()
            Count = 0
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
    Write-Host "Found $($tenantIds.Count) enabled tenant IDs: $($tenantIds -join ', ')"    # Download hunt queries from blob storage using centralized authentication
    $containerName = "huntquery"
    $ctx = Get-StorageTableContext
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
        return
    }
    
    if ($huntQueries.Count -eq 0) {
        Write-Host "No valid hunt queries loaded from blob storage."
        return
    }
    
    Write-Host "Successfully loaded $($huntQueries.Count) hunt queries" 
    $functionUrl = [System.Environment]::GetEnvironmentVariable('WEBSITE_HOSTNAME', 'Process')
    $functionKey = $env:AZURE_FUNCTIONS_ENVIRONMENT
    if ([string]::IsNullOrEmpty($functionKey)) {
        Write-Host "Using anonymous authentication for internal function call"
        $useAuthentication = $false
    } else {
        Write-Host "Using internal authentication for function-to-function call"
        $useAuthentication = $true
    }

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
            
            $headers = @{
                'Content-Type' = 'application/json'
            }
            
            if ($useAuthentication) {
                $headers['x-functions-key'] = $functionKey
                Write-Host "Using internal function key authentication for Tenant: $tenantId"
            } else {
                Write-Host "Using anonymous authentication for Tenant: $tenantId (internal call)"
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

