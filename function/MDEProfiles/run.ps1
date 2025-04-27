# MDEProfiles Function App
# 0.0.1

using namespace System.Net

param($Request)

try {
    # Get parameters
    $TenantId   = Get-RequestParam -Name "TenantId"   -Request $Request
    $DeviceIds  = Get-RequestParam -Name "DeviceIds"  -Request $Request
    $allDevices = Get-RequestParam -Name "allDevices" -Request $Request
    $ps1Name    = Get-RequestParam -Name "ps1Name"    -Request $Request

    # Validate parameters
    $missingParams = @()
    if ([string]::IsNullOrEmpty($TenantId))   { $missingParams += "TenantId" }
    if ([string]::IsNullOrEmpty($DeviceIds) -and $allDevices -ne $true) { $missingParams += "DeviceIds" }
    if ([string]::IsNullOrEmpty($ps1Name))    { $missingParams += "ps1Name" }
    if ($missingParams.Count -gt 0) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body = "$($missingParams -join ', ') are required query parameters."
        })
        return
    }

    Write-Host "Request parameters:"
    Write-Host "Tenant ID: $TenantId"
    Write-Host "DeviceIds: $DeviceIds"
    Write-Host "allDevices: $allDevices"
    Write-Host "ps1Name: $ps1Name"

    # Get environment variables
    $spnId       = [System.Environment]::GetEnvironmentVariable('SPNID', 'Process')
    $keyVaultName= [System.Environment]::GetEnvironmentVariable('AZURE_KEYVAULT', 'Process')

    # Connect to MDE
    $token = Connect-MDE -TenantId $TenantId -SpnId $spnId -keyVaultName $keyVaultName
    Write-Host "Successfully retrieved access token for MDE."

    # Get all devices if requested
    if ($allDevices -eq $true) {
        Write-Host "Getting all devices"
        $Filter = "contains(osPlatform, 'Windows')"
        $machines = Get-Machines -token $token -Filter $Filter | ConvertFrom-Json
        if ($null -ne $machines) {
            $DeviceIds = @($machines | ForEach-Object { $_.Id })
        } else {
            $DeviceIds = @()
        }
        Write-Host "Machines returned: $($machines.Count)"
        Write-Host "DeviceIds: $($DeviceIds -join ' ')"
    }

    # Normalize $DeviceIds to always be an array of strings
    if ($null -eq $DeviceIds) {
        $DeviceIds = @()
    } elseif ($DeviceIds -is [string]) {
        $DeviceIds = $DeviceIds -split '[\s,;]+' | Where-Object { $_ -ne "" }
    } elseif ($DeviceIds -is [System.Collections.IEnumerable]) {
        $DeviceIds = @($DeviceIds | ForEach-Object { "$_" } | Where-Object { $_ -ne "" })
    } else {
        $DeviceIds = @("$DeviceIds")
    }

    if ($DeviceIds.Count -eq 0) {
        Write-Host "No DeviceIds to process."
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body = "No DeviceIds to process."
        })
        return
    }

    # Upload the specified script to Tenant Library
    Invoke-UploadLR -token $token -fileName $ps1Name -folderName "./MDEProfiles"
    Write-Host "Successfully uploaded file: $ps1Name"

    # Use ForEach-Object -Parallel to run the script on all devices
    Write-Host "Invoking LRScript for all DeviceIds..."

    # Concurrency limit for parallel execution
    $throttleLimit = 5 

    if ($DeviceIds.Count -gt 0) {
        $lrResultsFlat = $DeviceIds | ForEach-Object -Parallel {
            param($_)
            $DeviceId = $_
            Write-Host "Running LRScript for DeviceId: $DeviceId"
            Import-Module "$using:PSScriptRoot\..\MDEAutomator\MDEAutomator.psm1" -Force
            try {
                $jsonResult = Invoke-LRScript -DeviceIds @($DeviceId) -scriptName $using:ps1Name -token $using:token
                $result = $jsonResult | ConvertFrom-Json
                if ($result -is [System.Collections.IEnumerable]) {
                    return $result
                } else {
                    return @($result)
                }
            } catch {
                return [PSCustomObject]@{
                    DeviceId = $DeviceId
                    Success = $false
                    Transcript = "Exception: $($_.Exception.Message)"
                }
            }
        } -ThrottleLimit $throttleLimit
    } else {
        $lrResultsFlat = @()
    }

    # Flatten results if needed
    $lrResultsFlat2 = @()
    foreach ($r in $lrResultsFlat) {
        if ($r -is [System.Collections.IEnumerable]) {
            $lrResultsFlat2 += $r
        } else {
            $lrResultsFlat2 += @($r)
        }
    }

    # Fetch output in parallel as well, again enumerate explicitly
    $outputResults = $lrResultsFlat2 | ForEach-Object -Parallel {
        param($_)
        $res = $_
        Import-Module "$using:PSScriptRoot\..\MDEAutomator\MDEAutomator.psm1" -Force
        $DeviceId = $res.DeviceId
        $MachineActionId = $res.MachineActionId
        $Success = $res.Success

        $outputObj = [PSCustomObject]@{
            DeviceId        = $DeviceId
            MachineActionId = $MachineActionId
            Success         = $Success
            ExitCode        = $null
            ScriptOutput    = $null
            ScriptErrors    = $null
            Transcript      = $null
        }

        if ($Success -and $MachineActionId) {
            try {
                $scriptOutput = Get-LiveResponseOutput -machineActionId $MachineActionId -token $using:token
                if ($scriptOutput -ne $false) {
                    $outputObj.ExitCode     = $scriptOutput.ExitCode
                    $outputObj.ScriptOutput = $scriptOutput.ScriptOutput
                    $outputObj.ScriptErrors = $scriptOutput.ScriptErrors
                    $outputObj.Transcript   = $scriptOutput | ConvertTo-Json -Depth 10
                } else {
                    $outputObj.Success = $false
                    $outputObj.Transcript = "Failed to retrieve script output"
                }
            } catch {
                $outputObj.Success = $false
                $outputObj.Transcript = "Exception: $($_.Exception.Message)"
            }
        } else {
            $outputObj.Transcript = $res.Transcript
        }
        return $outputObj
    } -ThrottleLimit $throttleLimit

    Write-Host "Final Aggregated Results: $($outputResults | ConvertTo-Json -Depth 100)"

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body = $outputResults | ConvertTo-Json -Depth 100
    })
} catch {
    Write-Host "Unhandled exception: $($_.Exception.Message)"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body = "Unhandled exception: $($_.Exception.Message)"
    })
}