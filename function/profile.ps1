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
Import-Module -Name Az.KeyVault
Import-Module -Name Az.Storage

# Import custom modules
Import-Module -Name ./MDEAutomator
