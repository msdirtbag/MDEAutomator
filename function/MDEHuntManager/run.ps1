# MDEHuntManager Function App
# 1.6.0

using namespace System.Net

param($Request)

# Reconnect to Azure
$ManagedIdentityId = [System.Environment]::GetEnvironmentVariable('AZURE_CLIENT_ID', 'Process')
Disable-AzContextAutosave -Scope Process | Out-Null
Connect-AzAccount -Identity -AccountId $ManagedIdentityId | Out-Null
$subscriptionId = [System.Environment]::GetEnvironmentVariable('SUBSCRIPTION_ID', 'Process')
Set-AzContext -Subscription $subscriptionId -ErrorAction Stop

function Test-NullOrEmpty {
    param (
        [string]$Value,
        [string]$ParamName
    )
    if (-not $Value) {
        throw "Missing required parameter: $ParamName"
    }
}

function Get-Queries {
    try {
        Write-Host "Starting Get-Queries operation"
        
        # Get storage account name from environment
        $storageAccountName = [System.Environment]::GetEnvironmentVariable('STORAGE_ACCOUNT', 'Process')
        if ([string]::IsNullOrEmpty($storageAccountName)) {
            throw "STORAGE_ACCOUNT environment variable is required"
        }
        
        $containerName = "huntquery"
        
        # Create storage context using User Managed Identity
        try {
            $ctx = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount
        } catch {
            throw "Failed to create storage context with UMI: $($_.Exception.Message)"
        }
        
        # Get all .csl files from the container
        $blobs = Get-AzStorageBlob -Container $containerName -Context $ctx | Where-Object { 
            $_.Name -like '*.csl' -or $_.Name -like '*.kql'
        }
        
        if ($blobs.Count -eq 0) {
            return @{
                Status = "Success"
                Message = "No hunt query files found in container"
                Queries = @()
                Count = 0
                Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
            }
        }
        
        $queryList = @()
        foreach ($blob in $blobs) {
            $queryInfo = @{
                FileName = $blob.Name
                LastModified = $blob.LastModified
                Size = $blob.Length
                BlobType = $blob.BlobType
                ETag = $blob.ETag
            }
            $queryList += $queryInfo
        }
        
        Write-Host "Retrieved $($queryList.Count) hunt query files successfully"
        
        return @{
            Status = "Success"
            Message = "Retrieved $($queryList.Count) hunt query file(s) from storage"
            Queries = $queryList
            Count = $queryList.Count
            Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
        
    } catch {
        $errorMessage = "Failed to retrieve hunt queries: $($_.Exception.Message)"
        Write-Error $errorMessage
        return @{
            Status = "Error"
            Message = $errorMessage
            Queries = @()
            Count = 0
            Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    }
}

function Add-Query {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Query,
        [Parameter(Mandatory = $true)]
        [string]$QueryName
    )
    
    try {
        Write-Host "Starting Add-Query operation"

        # Ensure filename has .csl extension
        if (-not $QueryName.EndsWith('.csl') -and -not $QueryName.EndsWith('.kql')) {
            $QueryName = "$QueryName.csl"
        }
        
        # Get storage account name from environment
        $storageAccountName = [System.Environment]::GetEnvironmentVariable('STORAGE_ACCOUNT', 'Process')
        if ([string]::IsNullOrEmpty($storageAccountName)) {
            throw "STORAGE_ACCOUNT environment variable is required"
        }
        
        $containerName = "huntquery"
        
        # Create storage context using User Managed Identity
        try {
            $ctx = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount
            Write-Host "Storage context created successfully for blob operations using UMI"
        } catch {
            throw "Failed to create storage context with UMI: $($_.Exception.Message)"
        }
        
        # Create temporary file with query content
        $tempFile = [System.IO.Path]::GetTempFileName()
        try {
            Set-Content -Path $tempFile -Value $Query -Encoding UTF8
            
            # Upload to blob storage
            $blob = Set-AzStorageBlobContent -File $tempFile -Container $containerName -Blob $QueryName -Context $ctx -Force
            
            Write-Host "Successfully uploaded hunt query: $QueryName"
            
            return @{
                Status = "Success"
                Message = "Hunt query '$QueryName' uploaded successfully"
                FileName = $QueryName
                QueryLength = $Query.Length
                Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
                BlobInfo = @{
                    Name = $blob.Name
                    LastModified = $blob.LastModified
                    ETag = $blob.ETag
                }
            }
            
        } finally {
            # Clean up temporary file
            if (Test-Path $tempFile) {
                Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            }
        }
        
    } catch {
        $errorMessage = "Failed to add hunt query: $($_.Exception.Message)"
        Write-Error $errorMessage
        return @{
            Status = "Error"
            Message = $errorMessage
            Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    }
}

function Undo-Query {
    param (
        [Parameter(Mandatory = $true)]
        [string]$QueryName
    )
    
    try {
        Write-Host "Starting Undo-Query operation"
        
        # Get storage account name from environment
        $storageAccountName = [System.Environment]::GetEnvironmentVariable('STORAGE_ACCOUNT', 'Process')
        if ([string]::IsNullOrEmpty($storageAccountName)) {
            throw "STORAGE_ACCOUNT environment variable is required"
        }
        
        $containerName = "huntquery"
        
        # Create storage context using User Managed Identity
        try {
            $ctx = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount
            Write-Host "Storage context created successfully for blob operations using UMI"
        } catch {
            throw "Failed to create storage context with UMI: $($_.Exception.Message)"
        }
        
        # Check if blob exists first
        try {
            $blob = Get-AzStorageBlob -Container $containerName -Blob $QueryName -Context $ctx -ErrorAction Stop
            Write-Host "Found hunt query file: $QueryName"
        } catch {
            return @{
                Status = "Error"
                Message = "Hunt query file '$QueryName' not found in container"
                Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
            }
        }
        
        # Remove the blob
        Remove-AzStorageBlob -Container $containerName -Blob $QueryName -Context $ctx -Force
        
        Write-Host "Successfully removed hunt query: $QueryName"
        
        return @{
            Status = "Success"
            Message = "Hunt query '$QueryName' removed successfully"
            FileName = $QueryName
            Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
        
    } catch {
        $errorMessage = "Failed to remove hunt query: $($_.Exception.Message)"
        Write-Error $errorMessage
        return @{
            Status = "Error"
            Message = $errorMessage
            Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    }
}

try {
    # Get request parameters
    $Function = Get-RequestParam -Name "Function" -Request $Request
    
    Test-NullOrEmpty $Function "Function"
    
    $Result = [HttpStatusCode]::OK
    Write-Host "Executing Function: $Function"
    
    $output = switch ($Function) {
        'GetQueries'     { 
            Get-Queries 
        }
        'AddQuery'       { 
            $queryContent = Get-RequestParam -Name "Query" -Request $Request
            $queryFileName = Get-RequestParam -Name "QueryName" -Request $Request
            Add-Query -Query $queryContent -QueryName $queryFileName 
        }
        'UndoQuery'      { 
            $queryFileName = Get-RequestParam -Name "QueryName" -Request $Request
            Undo-Query -QueryName $queryFileName
        }         
        default { throw "Invalid function specified: $Function" }
    }

    $Body = $output | ConvertTo-Json -Depth 100
}
catch {
    $Result = [HttpStatusCode]::InternalServerError
    $Body = "Error executing function: $($_.Exception.Message)"
    Write-Error $_.Exception.Message
}

# Return response
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = $Result
    Body = $Body
})