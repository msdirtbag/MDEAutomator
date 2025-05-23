# MDECDManager Function App
# 1.5.7

using namespace System.Net

param($Request)

try {
    # Get request parameters
    $TenantId = Get-RequestParam -Name "TenantId" -Request $Request
    
    # Get environment variables
    $spnId = [System.Environment]::GetEnvironmentVariable('SPNID', 'Process')
    $ManagedIdentityId = [System.Environment]::GetEnvironmentVariable('AZURE_CLIENT_ID', 'Process')
    $StorageAccountName = [System.Environment]::GetEnvironmentVariable('STORAGE_ACCOUNT', 'Process')
    $ContainerName = "detections"

    # Connect to MDE
    Connect-MDE -TenantId $TenantId -SpnId $spnId -ManagedIdentityId $ManagedIdentityId

    # Reconnect to Azure after MDE connection
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity -AccountId $ManagedIdentityId | Out-Null
    $subscriptionId = [System.Environment]::GetEnvironmentVariable('SUBSCRIPTION_ID', 'Process')
    Set-AzContext -Subscription $subscriptionId -ErrorAction Stop

    # Connect to Azure Storage
    $ctx = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount

    # Download all JSON files from 'detections' container
    $blobs = Get-AzStorageBlob -Container $ContainerName -Context $ctx | Where-Object { $_.Name -like '*.json' }
    if (-not $blobs) {
        throw "No JSON files found in the 'detections' blob container."
    }

    $localTemp = [System.IO.Path]::GetTempPath()
    $repoRules = @()
    foreach ($blob in $blobs) {
        $localFile = Join-Path $localTemp $blob.Name
        Get-AzStorageBlobContent -Blob $blob.Name -Container $ContainerName -Destination $localFile -Context $ctx -Force | Out-Null
        try {
            $jsonContent = Get-Content -Path $localFile -Raw | ConvertFrom-Json
            $repoRules += [PSCustomObject]@{
                FileName = $blob.Name
                Content = $jsonContent
            }
        } catch {
            Write-Host "Error processing JSON file: $($blob.Name). Error: $_"
        }
    }

    if (-not $repoRules) {
        throw "No valid repository rules found."
    }

    $currentRules = Get-DetectionRules
    Write-Host "Current detection rules: $($currentRules.Count)"

    $installedCount = 0
    $updatedCount = 0

    if (-not $currentRules) {
        Write-Host "No current detection rules found. Installing all repository rules."
        foreach ($repoRule in $repoRules) {
            Install-DetectionRule -jsonContent $repoRule.Content
            $installedCount++
        }
    } else {
        foreach ($repoRule in $repoRules) {
            $repoDisplayName = $repoRule.Content.DisplayName.ToLower()
            $currentRule = $currentRules | Where-Object { $_.displayName.ToLower() -eq $repoDisplayName } | Select-Object -First 1
            if ($currentRule) {
                Write-Host "Updating rule: $($repoRule.Content.DisplayName)"
                Update-DetectionRule -RuleId $currentRule.id -jsonContent $repoRule.Content
                $updatedCount++
            } else {
                Write-Host "Installing new rule: $($repoRule.Content.DisplayName)"
                Install-DetectionRule -jsonContent $repoRule.Content
                $installedCount++
            }
        }
    }
    $Body = @{
        Installed = $installedCount
        Updated   = $updatedCount
        Message   = "Sync complete"
    }
    $Result = [HttpStatusCode]::OK
}
catch {
    $Result = [HttpStatusCode]::InternalServerError
    $Body = "Error executing function: $($_.Exception.Message)"
    Write-Error $_.Exception.Message
}

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = $Result
    Body = $Body
})