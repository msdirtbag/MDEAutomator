# Example Base Parameters
param(
    [string]$SpnId = "",
    [securestring]$SpnSecret = "",
    [string]$TenantId = ""
)

param(
    [string]$SpnId = "",
    [string]$keyVaultName = ""
)

param(
    [string]$SpnId = "",
    [string]$TenantId = "",
    [string]$keyVaultName = ""
)

# Example Base Usage
Connect-MDE -SpnId $SpnId -SpnSecret $SpnSecret -TenantId $TenantId