# MDECDManager Function App
# 1.6.0

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

    # 1. Get current tenant rules first
    $currentRules = Get-DetectionRules
    Write-Host "Current detection rules: $($currentRules.Count)"

    # 2. Get blob library
    $ctx = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount
    $blobs = Get-AzStorageBlob -Container $ContainerName -Context $ctx | Where-Object { $_.Name -like '*.json' }
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

    # 3. Backup tenant rules not found in blob library
    $repoRuleNames = $repoRules | ForEach-Object { $_.Content.DisplayName.ToLower() }
    $tenantOnlyRules = $currentRules | Where-Object { $repoRuleNames -notcontains $_.displayName.ToLower() }
    foreach ($rule in $tenantOnlyRules) {
        try {
            $sanitizedName = ($rule.displayName -replace '[^a-zA-Z0-9_-]', '_')
            $backupFileName = ("{0}-bak.json" -f $sanitizedName)
            $ruleJson = $rule | ConvertTo-Json -Depth 10
            $localBackupPath = Join-Path $localTemp $backupFileName
            $ruleJson | Out-File -FilePath $localBackupPath -Encoding utf8 -Force
            Set-AzStorageBlobContent -File $localBackupPath -Container $ContainerName -Blob $backupFileName -Context $ctx -Force | Out-Null
            Write-Host "Backed up tenant-only rule: $($rule.displayName) to blob storage as $backupFileName"
        } catch {
            Write-Host "Failed to back up rule: $($rule.displayName). Error: $_"
        }
    }

    # 4. Filter out any -bak.json files from repoRules so they are not repushed
    $repoRules = $repoRules | Where-Object { -not $_.FileName.ToLower().EndsWith('-bak.json') }

    $installedCount = 0
    $updatedCount = 0

    # 5. Install/update rules based on the non -bak.json rules found in the library
    foreach ($repoRule in $repoRules) {
        $repoDisplayName = $repoRule.Content.DisplayName.ToLower()
        $currentRule = $currentRules | Where-Object { $_.displayName.ToLower() -eq $repoDisplayName } | Select-Object -First 1
        if ($currentRule) {
            try {
                Write-Host "Updating rule: $($repoRule.Content.DisplayName)"
                Update-DetectionRule -RuleId $currentRule.id -jsonContent $repoRule.Content
                $updatedCount++
            } catch {
                Write-Host "Failed to update rule: $($repoRule.Content.DisplayName). Error: $_"
            }
        } else {
            try {
                Write-Host "Installing new rule: $($repoRule.Content.DisplayName)"
                Install-DetectionRule -jsonContent $repoRule.Content
                $installedCount++
            } catch {
                Write-Host "Failed to install new rule: $($repoRule.Content.DisplayName). Error: $_"
            }
        }
    }
    Write-Host "Sync complete: Installed $installedCount rules, Updated $updatedCount rules."
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