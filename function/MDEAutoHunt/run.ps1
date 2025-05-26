# MDEAutoHunt Function App
# 1.5.8

using namespace System.Net

param($Request)

try {
    # Get request parameters
    $TenantId = Get-RequestParam -Name "TenantId" -Request $Request
    $Queries  = Get-RequestParam -Name "Queries"  -Request $Request

    # Normalize Queries to always be an array of non-empty strings
    if ($null -eq $Queries) {
        $Queries = @()
    } elseif ($Queries -is [string]) {
        $Queries = $Queries -split '[\r\n]+|,|;' | Where-Object { $_.Trim() -ne "" }
    } elseif ($Queries -is [System.Collections.IEnumerable]) {
        $Queries = @($Queries | ForEach-Object { "$_" } | Where-Object { $_.Trim() -ne "" })
    } else {
        $Queries = @("$Queries")
    }

    # If no queries to process, return early
    if ($Queries.Count -eq 0) {
        Write-Host "No Queries to process."
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body = "No Queries to process."
        })
        return
    }

    # Get environment variables
    $spnId = [System.Environment]::GetEnvironmentVariable('SPNID', 'Process')
    $ManagedIdentityId = [System.Environment]::GetEnvironmentVariable('AZURE_CLIENT_ID', 'Process')
    $storageAccountName = [System.Environment]::GetEnvironmentVariable('STORAGE_ACCOUNT', 'Process')

    # Connect to Graph
    Connect-MDE -TenantId $TenantId -SpnId $spnId -ManagedIdentityId $ManagedIdentityId

    # Reconnect to Azure after MDE connection
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity -AccountId $ManagedIdentityId | Out-Null
    $subscriptionId = [System.Environment]::GetEnvironmentVariable('SUBSCRIPTION_ID', 'Process')
    Set-AzContext -Subscription $subscriptionId -ErrorAction Stop

    $throttleLimit = 10 # Adjust as needed for parallel processing
    $containerName = "output"

    # Prepare storage context
    $ctx = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount

    # Main orchestration: process each query in parallel
    $huntResults = $Queries | ForEach-Object -Parallel {
        param($_)
        $query = $_
        Import-Module "$using:PSScriptRoot\..\MDEAutomator\MDEAutomator.psm1" -Force
        try {
            $result = Invoke-AdvancedHunting -Queries @($query)
            $response = $result[0].Response

            # Create a unique blob name for each query
            $timestamp = Get-Date -Format "yyyyMMddHHmmss"
            $randomstring = [System.Guid]::NewGuid().ToString()
            $blobName = "query_${randomstring}_${timestamp}.json"

            # Convert response to JSON and save to temp file
            $tempFile = [System.IO.Path]::GetTempFileName()
            $response | ConvertTo-Json -Depth 100 | Out-File -FilePath $tempFile -Encoding utf8

            # Upload to blob storage
            Set-AzStorageBlobContent -File $tempFile -Container $using:containerName -Blob $blobName -Context $using:ctx -Force | Out-Null

            # Clean up temp file
            Remove-Item $tempFile -Force

            # Only return Status for success
            [PSCustomObject]@{
                Status = "Success"
            }
        } catch {
            # Return Status and Error for failure
            [PSCustomObject]@{
                Status = "Error"
                Error  = $_.Exception.Message
            }
        }
    } -ThrottleLimit $throttleLimit

    # Return the results as the HTTP response
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body = $huntResults | ConvertTo-Json -Depth 50
    })
}
catch {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body = "Error executing function: $($_.Exception.Message)"
    })
}