# MDEHuntManager Function App

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

function Get-Query {
    param (
        [Parameter(Mandatory = $true)]
        [string]$QueryName
    )
    try {
        Write-Host "Starting Get-Query operation for: $QueryName"
        
        # Get storage account name from environment
        $storageAccountName = [System.Environment]::GetEnvironmentVariable('STORAGE_ACCOUNT', 'Process')
        if ([string]::IsNullOrEmpty($storageAccountName)) {
            throw "STORAGE_ACCOUNT environment variable is required"
        }
        
        $containerName = "huntquery"
        $localTemp = [System.IO.Path]::GetTempPath()
        
        # Create storage context using User Managed Identity
        try {
            $ctx = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount
        } catch {
            throw "Failed to create storage context with UMI: $($_.Exception.Message)"
        }
        
        # Try to find the query file with .kql or .csl extension
        $possibleNames = @(
            "$QueryName.kql",
            "$QueryName.csl",
            $QueryName  # In case the extension is already included
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
                # Continue to next possible name
            }
        }
        
        if (-not $foundBlob) {
            return @{
                Status = "Error"
                Message = "Query file not found. Tried: $($possibleNames -join ', ')"
                QueryName = $QueryName
                Content = $null
                Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
            }
        }
        
        # Download and read the query content
        $localFile = Join-Path $localTemp $foundBlob.Name
        try {
            Get-AzStorageBlobContent -Blob $foundBlob.Name -Container $containerName -Destination $localFile -Context $ctx -Force | Out-Null
            $queryContent = Get-Content -Path $localFile -Raw
            
            # Clean up temp file
            if (Test-Path $localFile) {
                Remove-Item $localFile -Force
            }
            
            Write-Host "Successfully retrieved query content from: $($foundBlob.Name)"
            
            return @{
                Status = "Success"
                Message = "Successfully retrieved query content"
                QueryName = $QueryName
                FileName = $foundBlob.Name
                Content = $queryContent
                LastModified = $foundBlob.LastModified
                Size = $foundBlob.Length
                Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
            }
            
        } catch {
            # Clean up temp file on error
            if (Test-Path $localFile) {
                Remove-Item $localFile -Force
            }
            throw "Failed to download or read query content: $($_.Exception.Message)"
        }
        
    } catch {
        $errorMessage = "Failed to retrieve query '$QueryName': $($_.Exception.Message)"
        Write-Error $errorMessage
        return @{
            Status = "Error"
            Message = $errorMessage
            QueryName = $QueryName
            Content = $null
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

function Update-Query {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Query,
        [Parameter(Mandatory = $true)]
        [string]$QueryName
    )
    
    $tempFile = $null
    $startTime = Get-Date
    
    try {
        Write-Host "Starting Update-Query operation for: $QueryName at $($startTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
        
        # Get storage account name from environment
        $storageAccountName = [System.Environment]::GetEnvironmentVariable('STORAGE_ACCOUNT', 'Process')
        $containerName = "huntquery"
        $ctx = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount -ErrorAction Stop
        
        # Smart file discovery - try multiple filename variations to find existing file
        $possibleNames = @(
            $QueryName,
            "$QueryName.kql",
            "$QueryName.csl"
        )
        
        # Remove duplicates and filter out invalid names
        $possibleNames = $possibleNames | Where-Object { $_ -and $_.Trim() } | Select-Object -Unique
        
        $foundBlob = $null
        $actualFileName = $null
        
        # Look for existing file first
        foreach ($fileName in $possibleNames) {
            try {
                $blob = Get-AzStorageBlob -Container $containerName -Context $ctx -Blob $fileName -ErrorAction SilentlyContinue
                if ($blob) {
                    $foundBlob = $blob
                    $actualFileName = $fileName
                    Write-Host "Found existing query file to update: $actualFileName"
                    break
                }
            } catch {
                # Continue to next possible name
                Write-Host "File not found: $fileName, trying next option"
            }
        }
        
        # Create temporary file with new query content
        $tempFile = [System.IO.Path]::GetTempFileName()
        Set-Content -Path $tempFile -Value $Query -Encoding UTF8
        
        # Upload/overwrite the query file
        $updatedBlob = Set-AzStorageBlobContent -File $tempFile -Container $containerName -Blob $actualFileName -Context $ctx -Force
        
        $endTime = Get-Date
        $duration = $endTime - $startTime
        
        $operation = if ($foundBlob) { "Updated" } else { "Created" }
        Write-Host "Successfully $($operation.ToLower()) query: $actualFileName (Duration: $($duration.TotalSeconds.ToString('F2'))s)"
        
        return @{
            Status = "Success"
            Operation = $operation
            Message = "Query '$actualFileName' $($operation.ToLower()) successfully"
            QueryName = $QueryName
            FileName = $actualFileName
            ContentLength = $Query.Length
            BackupInfo = $backupInfo
            LastModified = $updatedBlob.LastModified
            ETag = $updatedBlob.ETag
            Duration = "$($duration.TotalSeconds.ToString('F2'))s"
            Timestamp = $endTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
            BlobInfo = @{
                Name = $updatedBlob.Name
                LastModified = $updatedBlob.LastModified
                ETag = $updatedBlob.ETag
            }
        }
        
    } catch {
        $endTime = Get-Date
        $duration = $endTime - $startTime
        $errorMessage = "Failed to update query '$QueryName': $($_.Exception.Message)"
        
        Write-Error $errorMessage
        Write-Host "Operation failed after $($duration.TotalSeconds.ToString('F2'))s"
        
        return @{
            Status = "Error"
            Operation = "Update"
            Message = $errorMessage
            QueryName = $QueryName
            ErrorDetails = @{
                Exception = $_.Exception.GetType().Name
                ErrorLine = $_.InvocationInfo.ScriptLineNumber
                ErrorPosition = $_.InvocationInfo.OffsetInLine
            }
            Duration = "$($duration.TotalSeconds.ToString('F2'))s"
            Timestamp = $endTime.ToString("yyyy-MM-ddTHH:mm:ss Z")
        }
        
    } finally {
        if ($tempFile -and (Test-Path $tempFile)) {
            try {
                Remove-Item $tempFile -Force -ErrorAction Stop
                Write-Host "Cleaned up temporary file: $tempFile"
            } catch {
                Write-Warning "Failed to clean up temporary file: $tempFile - $($_.Exception.Message)"
            }
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

function Save-HuntSchedule {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TenantId,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ClientName,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ScheduleName,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ScheduleTime,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [object]$HuntSchedule
    )
    
    try {
        Write-Host "Saving hunt schedule for TenantId: $TenantId, ClientName: $ClientName"
        
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
          # Generate a unique ID for this hunt schedule
        $scheduleId = [System.Guid]::NewGuid().ToString()
        
        # Serialize the hunt schedule object to JSON string
        if ($HuntSchedule -is [string]) {
            # Already a JSON string
            $huntScheduleJson = $HuntSchedule
        } else {
            # Convert object to JSON string
            $huntScheduleJson = $HuntSchedule | ConvertTo-Json -Depth 10 -Compress
        }
        
        # Create new entity with proper data types
        $entity = @{
            "PartitionKey" = [string]"HuntSchedule"
            "RowKey" = [string]$scheduleId
            "ScheduleName" = [string]$ScheduleName
            "ScheduleTime" = [string]$ScheduleTime
            "TenantId" = [string]$TenantId
            "ClientName" = [string]$ClientName
            "HuntSchedule" = [string]$huntScheduleJson
            "Enabled" = [bool]$true
            "CreatedDate" = [string](Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            "CreatedBy" = [string]"MDEAutomator"
        }
        
        # Add entity to table
        try {
            Write-Host "Adding hunt schedule to table..."
            Add-AzDataTableEntity -Context $context -Entity $entity -CreateTableIfNotExists | Out-Null
            Write-Host "Hunt schedule saved successfully with ID: $scheduleId"
        } catch {
            Write-Host "Failed to add hunt schedule to table: $($_.Exception.Message)"
            throw "Failed to add hunt schedule to storage table: $($_.Exception.Message)"
        }
        
        return @{
            Status = "Success"
            Message = "Hunt schedule saved successfully"
            ScheduleId = $scheduleId
            TenantId = $TenantId
            ClientName = $ClientName
            Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
        
    } catch {
        $errorMessage = "Failed to save hunt schedule: $($_.Exception.Message)"
        Write-Error $errorMessage
        
        return @{
            Status = "Error"
            Message = $errorMessage
            TenantId = $TenantId
            ClientName = $ClientName
            Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    }
}

function Remove-HuntSchedule {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ScheduleId
    )
    
    try {
        Write-Host "Starting Remove-HuntSchedule for schedule ID: $ScheduleId"
        
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
        
        # Check if schedule exists before trying to remove
        $existingEntity = Get-AzDataTableEntity -Context $context -Filter "PartitionKey eq 'HuntSchedule' and RowKey eq '$ScheduleId'" -ErrorAction SilentlyContinue
        
        if (-not $existingEntity) {
            return @{
                Status = "Warning"
                Message = "Hunt schedule with ID '$ScheduleId' not found in storage table"
                ScheduleId = $ScheduleId
                Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
            }
        }
        
        # Remove the schedule entity
        Remove-AzDataTableEntity -Context $context -Entity $existingEntity -ErrorAction Stop
        Write-Host "Hunt schedule '$ScheduleId' removed successfully"
        
        return @{
            Status = "Success"
            Message = "Hunt schedule '$ScheduleId' removed from storage table"
            ScheduleId = $ScheduleId
            Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
        
    } catch {
        $errorMessage = "Failed to remove hunt schedule: $($_.Exception.Message)"
        Write-Error $errorMessage
        return @{
            Status = "Error"
            Message = $errorMessage
            ScheduleId = $ScheduleId
            Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    }
}

function Disable-HuntSchedule {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ScheduleId
    )
    try {
        Write-Host "Disabling hunt schedule for ID: $ScheduleId"

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

        # Check if schedule exists
        $existingEntity = Get-AzDataTableEntity -Context $context -Filter "PartitionKey eq 'HuntSchedule' and RowKey eq '$ScheduleId'" -ErrorAction SilentlyContinue

        if (-not $existingEntity) {
            return @{
                Status = "Warning"
                Message = "Hunt schedule with ID '$ScheduleId' not found in storage table"
                ScheduleId = $ScheduleId
                Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
            }
        }

        # Update the Enabled property to false
        $existingEntity.Enabled = $false

        # Update the entity in the table
        Update-AzDataTableEntity -Context $context -Entity $existingEntity -ErrorAction Stop | Out-Null

        Write-Host "Hunt schedule '$ScheduleId' disabled successfully"

        return @{
            Status = "Success"
            Message = "Hunt schedule '$ScheduleId' disabled in storage table"
            ScheduleId = $ScheduleId
            Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    } catch {
        $errorMessage = "Failed to disable hunt schedule: $($_.Exception.Message)"
        Write-Error $errorMessage
        return @{
            Status = "Error"
            Message = $errorMessage
            ScheduleId = $ScheduleId
            Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    }
}

function Enable-HuntSchedule {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ScheduleId
    )
    try {
        Write-Host "Enabling hunt schedule for ID: $ScheduleId"

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

        # Check if schedule exists
        $existingEntity = Get-AzDataTableEntity -Context $context -Filter "PartitionKey eq 'HuntSchedule' and RowKey eq '$ScheduleId'" -ErrorAction SilentlyContinue

        if (-not $existingEntity) {
            return @{
                Status = "Warning"
                Message = "Hunt schedule with ID '$ScheduleId' not found in storage table"
                ScheduleId = $ScheduleId
                Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
            }
        }

        # Update the Enabled property to true
        $existingEntity.Enabled = $true

        # Update the entity in the table
        Update-AzDataTableEntity -Context $context -Entity $existingEntity -ErrorAction Stop | Out-Null

        Write-Host "Hunt schedule '$ScheduleId' enabled successfully"

        return @{
            Status = "Success"
            Message = "Hunt schedule '$ScheduleId' enabled in storage table"
            ScheduleId = $ScheduleId
            Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    } catch {
        $errorMessage = "Failed to enable hunt schedule: $($_.Exception.Message)"
        Write-Error $errorMessage
        return @{
            Status = "Error"
            Message = $errorMessage
            ScheduleId = $ScheduleId
            Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    }
}

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
                $huntScheduleObj = $entity.HuntSchedule | ConvertFrom-Json
                $scheduleInfo = @{
                    ScheduleId = $entity.RowKey
                    ScheduleTime = $entity.ScheduleTime
                    ScheduleName = $entity.ScheduleName
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
    # Get request parameters
    $Function = Get-RequestParam -Name "Function" -Request $Request
    $QueryName = Get-RequestParam -Name "QueryName" -Request $Request
    $HuntSchedule = Get-RequestParam -Name "HuntSchedule" -Request $Request
    $TenantId = Get-RequestParam -Name "TenantId" -Request $Request
    $ClientName = Get-RequestParam -Name "ClientName" -Request $Request
    $ScheduleName = Get-RequestParam -Name "ScheduleName" -Request $Request
    $ScheduleTime = Get-RequestParam -Name "ScheduleTime" -Request $Request
    $ScheduleId = Get-RequestParam -Name "ScheduleId" -Request $Request
    $EnabledOnly = Get-RequestParam -Name "EnabledOnly" -Request $Request -DefaultValue $true
    
    Test-NullOrEmpty $Function "Function"
    
    $Result = [HttpStatusCode]::OK
    Write-Host "Executing Function: $Function"
    
    $output = switch ($Function) {
        'GetQueries'     { Get-Queries }
        'GetQuery'       { Get-Query -QueryName $QueryName }
        'UpdateQuery'    { 
            $queryContent = Get-RequestParam -Name "Query" -Request $Request
            $queryFileName = Get-RequestParam -Name "QueryName" -Request $Request
            Update-Query -Query $queryContent -QueryName $queryFileName
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
        'SaveHuntSchedule' { 
            Test-NullOrEmpty $TenantId "TenantId"
            Test-NullOrEmpty $ClientName "ClientName"
            Test-NullOrEmpty $HuntSchedule "HuntSchedule"
            Test-NullOrEmpty $ScheduleName "ScheduleName"
            Test-NullOrEmpty $ScheduleTime "ScheduleTime"
            Save-HuntSchedule -TenantId $TenantId -ClientName $ClientName -HuntSchedule $HuntSchedule -ScheduleName $ScheduleName -ScheduleTime $ScheduleTime
        }
        'RemoveHuntSchedule' { 
            Test-NullOrEmpty $ScheduleId "ScheduleId" 
            Remove-HuntSchedule -ScheduleId $ScheduleId
        }
        'DisableHuntSchedule' { 
            Test-NullOrEmpty $ScheduleId "ScheduleId"
            Disable-HuntSchedule -ScheduleId $ScheduleId 
        }
        'EnableHuntSchedule' { 
            Test-NullOrEmpty $ScheduleId "ScheduleId" 
            Enable-HuntSchedule -ScheduleId $ScheduleId
        }
        'GetHuntSchedules' { 
            $EnabledOnly = Get-RequestParam -Name "EnabledOnly" -Request $Request -DefaultValue $true
            Get-HuntSchedules -EnabledOnly $EnabledOnly 
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