# Authenticate with Azure PowerShell using UMI.
if ($env:MSI_SECRET) {
    Disable-AzContextAutosave -Scope Process | Out-Null

    # Get the Client ID of the User Assigned Managed Identity from an environment variable
    $clientId = [System.Environment]::GetEnvironmentVariable('AZURE_CLIENT_ID', 'Process')
    Connect-AzAccount -Identity -AccountId $clientId | Out-Null
    $subscriptionId = [System.Environment]::GetEnvironmentVariable('SUBSCRIPTION_ID', 'Process')
    Set-AzContext -Subscription $subscriptionId -ErrorAction Stop
}

# Import PowerShell Gallery modules
Import-Module -Name Az.Accounts
Import-Module -Name Az.Storage 
Import-Module -Name PSAISuite
Import-Module -Name Microsoft.Graph.Authentication 
Import-Module -Name AzBobbyTables


# Import MDEAutomator module
Import-Module -Name ./MDEAutomator -ErrorAction Stop -Force