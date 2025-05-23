# MDEAutomator Main Function App
# 1.5.7

using namespace System.Net

param($Request)

function Test-NullOrEmpty {
    param (
        [string]$Value,
        [string]$ParamName
    )
    if (-not $Value) {
        throw "Missing required parameter: $ParamName"
    }
}

try {
    # Get request parameters
    $TenantId   = Get-RequestParam -Name "TenantId" -Request $Request
    $Function   = Get-RequestParam -Name "Function" -Request $Request
    $DeviceId   = Get-RequestParam -Name "DeviceId" -Request $Request
    $ActionId   = Get-RequestParam -Name "ActionId" -Request $Request
    $Sha1       = Get-RequestParam -Name "Sha1" -Request $Request
    $Url        = Get-RequestParam -Name "Url" -Request $Request
    $Ip         = Get-RequestParam -Name "Ip" -Request $Request

    # Validate required parameters
    Test-NullOrEmpty $TenantId "TenantId"
    Test-NullOrEmpty $Function "Function"

    # Get environment variables and connect
    $spnId = [System.Environment]::GetEnvironmentVariable('SPNID', 'Process')
    $ManagedIdentityId = [System.Environment]::GetEnvironmentVariable('AZURE_CLIENT_ID', 'Process')

    # Connect to MDE
    $token = Connect-MDE -TenantId $TenantId -SpnId $spnId -ManagedIdentityId $ManagedIdentityId

    $Result = [HttpStatusCode]::OK
    Write-Host "Executing Function: $Function"
    $output = switch ($Function) {
        'GetMachines'              { Get-Machines -token $token }
        'GetActions'               { Get-Actions -token $token }
        'UndoActions'              { Undo-Actions -token $token }
        'GetIPInfo'                { 
                                        Test-NullOrEmpty $Ip "Ip"
                                        Get-IPInfo -token $token -IPs @($Ip)
                                    }
        'GetFileInfo'              { 
                                        Test-NullOrEmpty $Sha1 "Sha1"
                                        Get-FileInfo -token $token -Sha1s @($Sha1)
                                    }
        'GetURLInfo'               { 
                                        Test-NullOrEmpty $Url "Url"
                                        Get-URLInfo -token $token -URLs @($Url)
                                    }
        'GetLoggedInUsers'         { 
                                        Test-NullOrEmpty $DeviceId "DeviceId"
                                        Get-LoggedInUsers -token $token -DeviceIds @($DeviceId)
                                    }
        'GetMachineActionStatus'   { 
                                        Test-NullOrEmpty $ActionId "ActionId"
                                        Get-MachineActionStatus -machineActionId $ActionId -token $token
                                    }
        'GetLiveResponseOutput'    { 
                                        Test-NullOrEmpty $ActionId "ActionId"
                                        Get-LiveResponseOutput -machineActionId $ActionId -token $token
                                    }
        default { throw "Invalid function specified: $Function" }
    }

    $Body = $output | ConvertTo-Json -Depth 100
}
catch {
    $Result = [HttpStatusCode]::InternalServerError
    $Body = "Error executing function: $($_.Exception.Message)"
    Write-Error $_.Exception.Message
}

# Return response
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = $Result
    Body = $Body
})