# MDEIncidentManager Function App

using namespace System.Net

param($Request)

try {
    # Get request parameters
    $TenantId = Get-RequestParam -Name "TenantId" -Request $Request
    $Function = Get-RequestParam -Name "Function" -Request $Request
    $IncidentIds = Get-RequestParam -Name "IncidentIds" -Request $Request
    $Comment = Get-RequestParam -Name "Comment" -Request $Request
    $Status = Get-RequestParam -Name "Status" -Request $Request
    $AssignedTo = Get-RequestParam -Name "AssignedTo" -Request $Request
    $Classification = Get-RequestParam -Name "Classification" -Request $Request
    $Determination = Get-RequestParam -Name "Determination" -Request $Request
    $CustomTags = Get-RequestParam -Name "CustomTags" -Request $Request
    $Description = Get-RequestParam -Name "Description" -Request $Request
    $DisplayName = Get-RequestParam -Name "DisplayName" -Request $Request
    $Severity = Get-RequestParam -Name "Severity" -Request $Request
    $ResolvingComment = Get-RequestParam -Name "ResolvingComment" -Request $Request
    $Summary = Get-RequestParam -Name "Summary" -Request $Request  

    # Get environment variables and connect
    $spnId = [System.Environment]::GetEnvironmentVariable('SPNID', 'Process')
    $ManagedIdentityId = [System.Environment]::GetEnvironmentVariable('AZURE_CLIENT_ID', 'Process')

    # Connect to MDE
    Connect-MDE -TenantId $TenantId -SpnId $spnId -ManagedIdentityId $ManagedIdentityId

    # Reconnect to Azure after MDE connection
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity -AccountId $ManagedIdentityId | Out-Null
    $subscriptionId = [System.Environment]::GetEnvironmentVariable('SUBSCRIPTION_ID', 'Process')
    Set-AzContext -Subscription $subscriptionId -ErrorAction Stop

    $Result = [HttpStatusCode]::OK
    $throttleLimit = 10     
    
    # Use ForEach-Object -Parallel for concurrent incident actions
    $results = $IncidentIds | ForEach-Object -Parallel {
        param($_)
        $incidentId = $_
        Import-Module "$using:PSScriptRoot\..\MDEAutomator\MDEAutomator.psm1" -Force
        
        try {
            $actionResult = switch ($using:Function) {
                'GetIncidents' { 
                    Get-Incidents 
                }
                'GetIncidentAlerts' { 
                    Get-IncidentAlerts -IncidentId $incidentId 
                }
                'UpdateIncident' { 
                    Update-Incident -IncidentId $incidentId -Status $using:Status -AssignedTo $using:AssignedTo `
                                   -Classification $using:Classification -Determination $using:Determination -CustomTags $using:CustomTags `
                                   -Description $using:Description -DisplayName $using:DisplayName -Severity $using:Severity `
                                   -ResolvingComment $using:ResolvingComment -Summary $using:Summary
                }
                'UpdateIncidentComment' { 
                    Update-IncidentComment -IncidentId $incidentId -Comment $using:Comment
                }
                default { 
                    throw "Invalid function specified: $using:Function"
                }
            }
            [PSCustomObject]@{
                IncidentId = $incidentId
                Status = "Success"
                Result = $actionResult
            }
        }
        catch {
            Write-Error "Error processing incident $incidentId : $($_.Exception.Message)"
            [PSCustomObject]@{
                IncidentId = $incidentId
                Status = "Error"
                Result = $_.Exception.Message
            }
        }
    } -ThrottleLimit $throttleLimit

    $Body = $results
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