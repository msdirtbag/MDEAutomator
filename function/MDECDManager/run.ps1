# MDECDManager Function App
# 0.0.1

using namespace System.Net

param($Request)

try {
    # Get request parameters
    $TenantId = Get-RequestParam -Name "TenantId" -Request $Request
    
    # Get environment variables
    $spnId = [System.Environment]::GetEnvironmentVariable('SPNID', 'Process')
    $keyVaultName = [System.Environment]::GetEnvironmentVariable('AZURE_KEYVAULT', 'Process')
    $StorageAccountName = [System.Environment]::GetEnvironmentVariable('STORAGE_ACCOUNT', 'Process')
    $ContainerName = "detections"

    # Connect to MDE
    Connect-MDEGraph -TenantId $TenantId -SpnId $spnId -keyVaultName $keyVaultName

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