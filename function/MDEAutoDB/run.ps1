# MDEAutoDB Main Function App

using namespace System.Net

param($Request)

# Helper function for parameter validation
function Test-NullOrEmpty {
    param (
        [string]$Value,
        [string]$ParamName
    )
    if ([string]::IsNullOrEmpty($Value)) {
        throw "Missing required parameter: $ParamName"
    }
}

function Save-TenantIdToTable {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TenantId,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ClientName
    )
      try {        
        
        Write-Host "Saving TenantId: $TenantId"
        # Get storage account name from environment
        $storageAccountName = [System.Environment]::GetEnvironmentVariable('STORAGE_ACCOUNT', 'Process')
        if ([string]::IsNullOrEmpty($storageAccountName)) {
            throw "STORAGE_ACCOUNT environment variable is required"
        }
          # Create context for AzBobbyTables
        try {
            $connectionString = [System.Environment]::GetEnvironmentVariable('WEBSITE_AZUREFILESCONNECTIONSTRING', 'Process')
            $context = New-AzDataTableContext -TableName "TenantIds" -ConnectionString $connectionString
        } catch {
            Write-Host "Failed to create context: $($_.Exception.Message)"
            throw "Unable to create storage context: $($_.Exception.Message)"
        }
          # Check if tenant already exists using AzBobbyTables
        try {
            Write-Host "Checking if tenant already exists..."
            $existingEntity = Get-AzDataTableEntity -Context $context -Filter "PartitionKey eq 'TenantConfig' and RowKey eq '$TenantId'" -ErrorAction SilentlyContinue
            if ($existingEntity) {
                Write-Host "Tenant already exists, returning warning"
                return @{
                    Status = "Warning"
                    Message = "Tenant ID '$TenantId' already exists in storage table"
                    TenantId = $TenantId
                    Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
                }
            }
        } catch {
            # Entity not found is expected, continue with creation
            Write-Host "Tenant not found (expected), proceeding with creation..."
        }
        
        # Create new entity using AzBobbyTables
        $entity = @{
            "PartitionKey" = "TenantConfig"
            "RowKey" = $TenantId
            "TenantId" = $TenantId
            "ClientName" = $ClientName
            "Enabled" = $true
            "AddedDate" = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            "AddedBy" = "MDEAutomator"
        }
        
        # Add entity to table using AzBobbyTables
        try {
            Write-Host "Adding tenant to table with AzBobbyTables..."
            Add-AzDataTableEntity -Context $context -Entity $entity -CreateTableIfNotExists | Out-Null
            Write-Host "TenantId saved successfully"
        } catch {
            Write-Host "Failed to add tenant to table: $($_.Exception.Message)"
            throw "Failed to add tenant to storage table: $($_.Exception.Message)"
        }
        
        return @{
            Status = "Success"
            Message = "Tenant ID '$TenantId' saved to storage table"
            TenantId = $TenantId
            Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
        
    } catch {
        $errorMessage = "Failed to save tenant ID: $($_.Exception.Message)"
        Write-Error $errorMessage
        
        return @{
            Status = "Error"
            Message = $errorMessage
            TenantId = $TenantId
            Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    }
}

function Remove-TenantIdFromTable {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TenantId
    )
      try {        
        
        Write-Host "Starting Remove-TenantIdFromTable for tenant: $TenantId"
        
        # Get storage account name from environment
        $storageAccountName = [System.Environment]::GetEnvironmentVariable('STORAGE_ACCOUNT', 'Process')
        if ([string]::IsNullOrEmpty($storageAccountName)) {
            throw "STORAGE_ACCOUNT environment variable is required"
        }
        
        # Create context for AzBobbyTables
        try {
            $connectionString = [System.Environment]::GetEnvironmentVariable('WEBSITE_AZUREFILESCONNECTIONSTRING', 'Process')
            $context = New-AzDataTableContext -TableName "TenantIds" -ConnectionString $connectionString
        } catch {
            Write-Host "Failed to create context: $($_.Exception.Message)"
            throw "Unable to create storage context: $($_.Exception.Message)"
        }
        # Check if tenant exists before trying to remove using AzBobbyTables
        $existingEntity = Get-AzDataTableEntity -Context $context -Filter "PartitionKey eq 'TenantConfig' and RowKey eq '$TenantId'" -ErrorAction SilentlyContinue
        
        if (-not $existingEntity) {
            return @{
                Status = "Warning"
                Message = "Tenant ID '$TenantId' not found in storage table"
                TenantId = $TenantId
                Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
            }
        }
        
        # Remove the tenant entity using AzBobbyTables
        Remove-AzDataTableEntity -Context $context -Entity $existingEntity -ErrorAction Stop
        Write-Host "Tenant ID '$TenantId' removed successfully"
        
        return @{
            Status = "Success"
            Message = "Tenant ID '$TenantId' removed from storage table"
            TenantId = $TenantId
            Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
        
    } catch {
        $errorMessage = "Failed to remove tenant ID: $($_.Exception.Message)"
        Write-Error $errorMessage
        return @{
            Status = "Error"
            Message = $errorMessage
            TenantId = $TenantId
            Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    }
}

function Get-TenantIdsFromTable {    
    try {        
          Write-Host "Starting Get-TenantIdsFromTable"
        
        # Get storage account name from environment
        $storageAccountName = [System.Environment]::GetEnvironmentVariable('STORAGE_ACCOUNT', 'Process')
        if ([string]::IsNullOrEmpty($storageAccountName)) {
            throw "STORAGE_ACCOUNT environment variable is required"
        }
        
        # Create context for AzBobbyTables 
        try {
            $connectionString = [System.Environment]::GetEnvironmentVariable('WEBSITE_AZUREFILESCONNECTIONSTRING', 'Process')
            $context = New-AzDataTableContext -TableName "TenantIds" -ConnectionString $connectionString
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
    # Get request parameters
    $TenantId = Get-RequestParam -Name "TenantId" -Request $Request
    $Function = Get-RequestParam -Name "Function" -Request $Request
    $ClientName = Get-RequestParam -Name "ClientName" -Request $Request  
    
    # Validate required Function parameter
    Test-NullOrEmpty $Function "Function"
    
    # Validate parameters based on function type
    switch ($Function) {
        'SaveTenantId' { 
            Test-NullOrEmpty $TenantId "TenantId"
            Test-NullOrEmpty $ClientName "ClientName"
        }
        'RemoveTenantId' { 
            Test-NullOrEmpty $TenantId "TenantId" 
        }

    }

    $Result = [HttpStatusCode]::OK
    Write-Host "Executing Function: $Function"
    
    $output = switch ($Function) {          
        'SaveTenantId'   { Save-TenantIdToTable -TenantId $TenantId -ClientName $ClientName }
        'RemoveTenantId' { Remove-TenantIdFromTable -TenantId $TenantId }
        'GetTenantIds'   { Get-TenantIdsFromTable }
        default          { 
            throw "Invalid function specified: $Function. Valid functions are: SaveTenantId, RemoveTenantId, GetTenantIds, SaveHuntSchedule, RemoveHuntSchedule, GetHuntSchedules" 
        }
    }

    $Body = $output | ConvertTo-Json -Depth 100 -Compress
}
catch {
    $Result = [HttpStatusCode]::InternalServerError
    $errorResponse = @{
        Status = "Error"
        Message = "Function execution failed: $($_.Exception.Message)"
        Function = $Function
        Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
    $Body = $errorResponse | ConvertTo-Json -Depth 100 -Compress
    Write-Error $_.Exception.Message
}

# Return response
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = $Result
    Body = $Body
})