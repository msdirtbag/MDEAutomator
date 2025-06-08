# MDEProfiles Function App
# 1.6.0

using namespace System.Net

param($Request)

try {
    # Extract and validate parameters from the incoming HTTP request
    $TenantId   = Get-RequestParam -Name "TenantId"   -Request $Request
    $DeviceIds  = Get-RequestParam -Name "DeviceIds"  -Request $Request
    $allDevices = Get-RequestParam -Name "allDevices" -Request $Request
    $ps1Name    = Get-RequestParam -Name "ps1Name"    -Request $Request

    # Validate required parameters
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

    # Retrieve environment variables for authentication
    $spnId        = [System.Environment]::GetEnvironmentVariable('SPNID', 'Process')
    $ManagedIdentityId = [System.Environment]::GetEnvironmentVariable('AZURE_CLIENT_ID', 'Process')

    # Connect to MDE
    $token = Connect-MDE -TenantId $TenantId -SpnId $spnId -ManagedIdentityId $ManagedIdentityId

    # Reconnect to Azure after MDE connection
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity -AccountId $ManagedIdentityId | Out-Null
    $subscriptionId = [System.Environment]::GetEnvironmentVariable('SUBSCRIPTION_ID', 'Process')
    Set-AzContext -Subscription $subscriptionId -ErrorAction Stop
    
    # Device discovery: get all Windows devices if requested
    if ($allDevices -eq $true) {
        Write-Host "Getting all devices"
        $Filter = "contains(osPlatform, 'Windows')"
        $machines = Get-Machines -token $token -Filter $Filter
        if ($null -ne $machines) {
            $DeviceIds = @($machines | ForEach-Object { $_.Id })
        } else {
            $DeviceIds = @()
        }
        Write-Host "Machines returned: $($machines.Count)"
        Write-Host "DeviceIds: $($DeviceIds -join ' ')"
    }

    # Normalize DeviceIds to always be an array of strings
    if ($null -eq $DeviceIds) {
        $DeviceIds = @()
    } elseif ($DeviceIds -is [string]) {
        $DeviceIds = $DeviceIds -split '[\s,;]+' | Where-Object { $_ -ne "" }
    } elseif ($DeviceIds -is [System.Collections.IEnumerable]) {
        $DeviceIds = @($DeviceIds | ForEach-Object { "$_" } | Where-Object { $_ -ne "" })
    } else {
        $DeviceIds = @("$DeviceIds")
    }

    # If no devices to process, return early
    if ($DeviceIds.Count -eq 0) {
        Write-Host "No DeviceIds to process."
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body = "No DeviceIds to process."
        })
        return
    }

    # Upload the specified script to the Tenant Library
    $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath ".\$ps1Name"
    Invoke-UploadLR -token $token -filePath $scriptPath
    Write-Host "Successfully uploaded file: $ps1Name"

    # Set concurrency limit for parallel execution
    $throttleLimit = 10

    # Run the script on all devices in parallel and collect results
    Write-Host "Invoking LRScript for all DeviceIds..."
    $lrResults = $DeviceIds | ForEach-Object -Parallel {
        param($_)
        $DeviceId = $_
        Write-Host "Running LRScript for DeviceId: $DeviceId"
        Import-Module "$using:PSScriptRoot\..\MDEAutomator\MDEAutomator.psm1" -Force
        try {
            $results = Invoke-LRScript -DeviceIds @($DeviceId) -scriptName $using:ps1Name -token $using:token
            # Always return an array for consistency
            foreach ($res in $results) { $res }
        } catch {
            return [PSCustomObject]@{
                DeviceId = $DeviceId
                Success = $false
                Transcript = "Exception: $($_.Exception.Message)"
            }
        }
    } -ThrottleLimit $throttleLimit

    # Fetch output for each device in parallel
    $outputResults = $lrResults | ForEach-Object -Parallel {
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
                    $outputObj.Transcript   = $scriptOutput
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

    # Return the results as the HTTP response
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body = $outputResults | ConvertTo-Json -Depth 100
    })
} catch {
    # Handle any unhandled exceptions in the function app
    Write-Host "Unhandled exception: $($_.Exception.Message)"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body = "Unhandled exception: $($_.Exception.Message)"
    })
}