# MDETIManager Function App

using namespace System.Net

param($Request)

function Install-DetectionRulefromStorage {
    param (
        [String]$RuleTitle
    )
    try {
        $StorageAccountName = [System.Environment]::GetEnvironmentVariable('STORAGE_ACCOUNT', 'Process')
        $ContainerName = "detections"
        $localTemp = [System.IO.Path]::GetTempPath()
        $ctx = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount
        $blobName = "$RuleTitle.json"
        $allBlobNames = (Get-AzStorageBlob -Container $ContainerName -Context $ctx | Select-Object -ExpandProperty Name)
        $blob = Get-AzStorageBlob -Container $ContainerName -Context $ctx -Blob $blobName -ErrorAction SilentlyContinue
        if ($blob) {
            $localFile = Join-Path $localTemp $blobName
            Get-AzStorageBlobContent -Blob $blobName -Container $ContainerName -Destination $localFile -Context $ctx -Force | Out-Null
            $jsonContent = Get-Content -Path $localFile -Raw | ConvertFrom-Json
            Install-DetectionRule -jsonContent $jsonContent
            Write-Host "Installed detection rule: $RuleTitle from blob $blobName"
        } else {
            Write-Host "No detection rule found in blob storage with DisplayName: $RuleTitle (expected blob: $blobName)"
        }
    } catch {
        Write-Host "Failed to install detection rule from storage for: $RuleTitle. Error: $_"
    }
}

function Get-DetectionsRulesfromStorage {
    try {
        $StorageAccountName = [System.Environment]::GetEnvironmentVariable('STORAGE_ACCOUNT', 'Process')
        $ContainerName = "detections"
        $localTemp = [System.IO.Path]::GetTempPath()
        $ctx = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount
        $blobs = Get-AzStorageBlob -Container $ContainerName -Context $ctx | Where-Object { $_.Name -like '*.json' -and $_.Name -notlike '*-bak.json' }
        $rules = @()
        foreach ($blob in $blobs) {
            $localFile = Join-Path $localTemp $blob.Name
            try {
                Get-AzStorageBlobContent -Blob $blob.Name -Container $ContainerName -Destination $localFile -Context $ctx -Force | Out-Null
                $fileContent = Get-Content -Path $localFile -Raw
                $jsonContent = $fileContent | ConvertFrom-Json
                if ($jsonContent.DisplayName) {
                    $rules += [PSCustomObject]@{
                        RuleTitle = $jsonContent.DisplayName
                        Query     = $fileContent
                    }
                }
            } catch {
                Write-Host "Error processing JSON file: $($blob.Name). Error: $_"
            }
        }
        return $rules
    } catch {
        Write-Host "Failed to retrieve detection rules from storage. Error: $_"
        return @()
    }
}

function Get-DeviceGroups {
    try {
        $DeviceGroups = Get-Machines -token $token
        return $DeviceGroups | Select-Object -ExpandProperty RbacGroupName | Select-Object -Unique
    } catch {
        Write-Host "Failed to retrieve device groups. Error: $_"
        return @()
    }
}

try {
    $TenantId = Get-RequestParam -Name "TenantId" -Request $Request
    $Function = Get-RequestParam -Name "Function" -Request $Request
    $Sha1s = Get-RequestParam -Name "Sha1s" -Request $Request
    $Sha256s = Get-RequestParam -Name "Sha256s" -Request $Request
    $IPs = Get-RequestParam -Name "IPs" -Request $Request
    $URLs = Get-RequestParam -Name "URLs" -Request $Request
    $IndicatorName = Get-RequestParam -Name "IndicatorName" -Request $Request
    $jsonContent = Get-RequestParam -Name "jsonContent" -Request $Request
    $RuleId = Get-RequestParam -Name "RuleId" -Request $Request
    $RuleTitle = Get-RequestParam -Name "RuleTitle" -Request $Request
    $DeviceGroups = Get-RequestParam -Name "DeviceGroups" -Request $Request

    $missingParams = @()
    if ([string]::IsNullOrEmpty($TenantId)) { $missingParams += "TenantId" }
    if ([string]::IsNullOrEmpty($Function)) { $missingParams += "Function" }

    if ($missingParams.Count -gt 0) {
        return Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body = "$($missingParams -join ', ') are required query parameters."
        })
    }

    $spnId = [System.Environment]::GetEnvironmentVariable('SPNID', 'Process')
    $ManagedIdentityId = [System.Environment]::GetEnvironmentVariable('AZURE_CLIENT_ID', 'Process')
    $token = Connect-MDE -TenantId $TenantId -SpnId $spnId -ManagedIdentityId $ManagedIdentityId

    # Reconnect to Azure after MDE connection
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity -AccountId $ManagedIdentityId | Out-Null
    $subscriptionId = [System.Environment]::GetEnvironmentVariable('SUBSCRIPTION_ID', 'Process')
    Set-AzContext -Subscription $subscriptionId -ErrorAction Stop

    $Result = [HttpStatusCode]::OK
    $Body = switch ($Function) {
        "InvokeTiFile" {
            if (-not $Sha1s -and -not $Sha256s) { throw "Sha1s or Sha256s parameter is required for Invoke-TiFile" }
            Invoke-TiFile -token $token -Sha1s $Sha1s -Sha256s $Sha256s -IndicatorName $IndicatorName -DeviceGroups $DeviceGroups
        }
        "UndoTiFile" {
            if (-not $Sha1s -and -not $Sha256s) { throw "Sha1s or Sha256s parameter is required for Undo-TiFile" }
            Undo-TiFile -token $token -Sha1s $Sha1s -Sha256s $Sha256s
        }
        "InvokeTiIP" {
            if (-not $IPs) { throw "IPs parameter is required for InvokeTiIP" }
            Invoke-TiIP -token $token -IPs $IPs -IndicatorName $IndicatorName -DeviceGroups $DeviceGroups
        }
        "UndoTiIP" {
            if (-not $IPs) { throw "IPs parameter is required for UndoTiIP" }
            Undo-TiIP -token $token -IPs $IPs
        }
        "InvokeTiURL" {
            if (-not $URLs) { throw "URLs parameter is required for InvokeTiURL" }
            Invoke-TiURL -token $token -URLs $URLs -IndicatorName $IndicatorName -DeviceGroups $DeviceGroups
        }
        "UndoTiURL" {
            if (-not $URLs) { throw "URLs parameter is required for UndoTiURL" }
            Undo-TiURL -token $token -URLs $URLs
        }
        "InvokeTiCert" {
            if (-not $Sha1s) { throw "Sha1s parameter is required for InvokeTiCert" }
            Invoke-TiCert -token $token -Sha1s $Sha1s -IndicatorName $IndicatorName -DeviceGroups $DeviceGroups
        }
        "UndoTiCert" {
            if (-not $Sha1s) { throw "Sha1s parameter is required for UndoTiCert" }
            Undo-TiCert -token $token -Sha1s $Sha1s 
        }
        "GetDeviceGroups" {
            Get-DeviceGroups -token $token
            Write-Host "Retrieved device groups"
        }
        "GetIndicators" {
            Get-Indicators -token $token
            Write-Host "Retrieved indicators"
        }
        "GetDetectionRules" {
            Get-DetectionRules
            Write-Host "Retrieved detection rules"
        }
        "GetDetectionRule" {
            Get-DetectionRule -RuleId $RuleId
            Write-Host "Retrieved detection rule"
        }
        "GetDetectionRulesfromStorage" {
            Get-DetectionsRulesfromStorage
            Write-Host "Retrieved detection rules from storage"
        }
        "InstallDetectionRule" {
            $parsedContent = $null
            if ($jsonContent -is [string]) {
                $parsedContent = $jsonContent | ConvertFrom-Json
            } else {
                $parsedContent = $jsonContent
            }
            Install-DetectionRule -jsonContent $parsedContent
        }
        "InstallDetectionRulefromStorage" {
            Install-DetectionRulefromStorage -RuleTitle $RuleTitle
        }
        "UpdateDetectionRule" {
            $parsedContent = $null
            if ($jsonContent -is [string]) {
                $parsedContent = $jsonContent | ConvertFrom-Json
            } else {
                $parsedContent = $jsonContent
            }
            Update-DetectionRule -jsonContent $parsedContent -RuleId $RuleId
        }
        "UndoDetectionRule" {
            Undo-DetectionRule -RuleId $RuleId
        }
        default {
            $Result = [HttpStatusCode]::BadRequest
            "Invalid function specified: $Function"
        }
    }
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