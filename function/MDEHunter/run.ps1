# MDEHunter Function App

using namespace System.Net

param($Request)

try {
    # Get request parameters
    $TenantId = Get-RequestParam -Name "TenantId" -Request $Request
    $FileName = Get-RequestParam -Name "FileName" -Request $Request

    if ([string]::IsNullOrWhiteSpace($TenantId) -or [string]::IsNullOrWhiteSpace($FileName)) {
        throw "TenantId and FileName are required parameters."
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

    $containerName = "huntquery"
    $outputContainer = "output"

    # Prepare storage context
    $ctx = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount

    # Find and download the specified file
    $blob = Get-AzStorageBlob -Container $containerName -Context $ctx | Where-Object { $_.Name -eq $FileName }
    if (-not $blob) {
        throw "File '$FileName' not found in container '$containerName'."
    }

    $localTemp = [System.IO.Path]::GetTempPath()
    $localFile = Join-Path $localTemp $FileName
    Get-AzStorageBlobContent -Blob $FileName -Container $containerName -Destination $localFile -Context $ctx -Force | Out-Null

    # Read the KQL query from the file
    $queryContent = Get-Content -Path $localFile -Raw
    if ([string]::IsNullOrWhiteSpace($queryContent)) {
        throw "Downloaded file '$FileName' is empty."
    }

    # Run the KQL query with Invoke-AdvancedHunting
    $result = Invoke-AdvancedHunting -Queries @($queryContent)
    $response = $result[0].Response

    # Save response as JSON in output blob container
    $timestamp = Get-Date -Format "yyyyMMddHHmmss"
    $blobName = "hunt_${($FileName -replace '[^a-zA-Z0-9]', '_')}_$timestamp.json"
    $tempJson = Join-Path $localTemp $blobName
    $response | ConvertTo-Json -Depth 100 | Out-File -FilePath $tempJson -Encoding utf8
    Set-AzStorageBlobContent -File $tempJson -Container $outputContainer -Blob $blobName -Context $ctx -Force | Out-Null

    # Clean up temp files
    if (Test-Path $localFile) {
        Remove-Item $localFile -Force
    }
    if (Test-Path $tempJson) {
        Remove-Item $tempJson -Force
    }

    # Return the result as the HTTP response
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body = $response | ConvertTo-Json -Depth 50
    })
}
catch {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body = "Error executing function: $($_.Exception.Message)"
    })
}