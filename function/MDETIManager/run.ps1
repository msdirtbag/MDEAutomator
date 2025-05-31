# MDETIManager Function App
# 1.5.9

using namespace System.Net

param($Request)

try {
    $TenantId = Get-RequestParam -Name "TenantId" -Request $Request
    $Function = Get-RequestParam -Name "Function" -Request $Request
    $Sha1s = Get-RequestParam -Name "Sha1s" -Request $Request
    $Sha256s = Get-RequestParam -Name "Sha256s" -Request $Request
    $IPs = Get-RequestParam -Name "IPs" -Request $Request
    $URLs = Get-RequestParam -Name "URLs" -Request $Request

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

    $Result = [HttpStatusCode]::OK
    $Body = switch ($Function) {
        "InvokeTiFile" {
            if (-not $Sha1s -and -not $Sha256s) { throw "Sha1s or Sha256s parameter is required for Invoke-TiFile" }
            Invoke-TiFile -token $token -Sha1s $Sha1s -Sha256s $Sha256s
        }
        "UndoTiFile" {
            if (-not $Sha1s -and -not $Sha256s) { throw "Sha1s or Sha256s parameter is required for Undo-TiFile" }
            Undo-TiFile -token $token -Sha1s $Sha1s -Sha256s $Sha256s
        }
        "InvokeTiIP" {
            if (-not $IPs) { throw "IPs parameter is required for InvokeTiIP" }
            Invoke-TiIP -token $token -IPs $IPs
        }
        "UndoTiIP" {
            if (-not $IPs) { throw "IPs parameter is required for UndoTiIP" }
            Undo-TiIP -token $token -IPs $IPs
        }
        "InvokeTiURL" {
            if (-not $URLs) { throw "URLs parameter is required for InvokeTiURL" }
            Invoke-TiURL -token $token -URLs $URLs
        }
        "UndoTiURL" {
            if (-not $URLs) { throw "URLs parameter is required for UndoTiURL" }
            Undo-TiURL -token $token -URLs $URLs
        }
        "InvokeTiCert" {
            if (-not $Sha1s) { throw "Sha1s parameter is required for InvokeTiCert" }
            Invoke-TiCert -token $token -Sha1s $Sha1s
        }
        "UndoTiCert" {
            if (-not $Sha1s) { throw "Sha1s parameter is required for UndoTiCert" }
            Undo-TiCert -token $token -Sha1s $Sha1s
        }
        "GetIndicators" {
            Get-Indicators -token $token
        }
        "GetDetectionRules" {
            Get-DetectionRules
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