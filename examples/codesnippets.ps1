# Example Base Parameters

# Option #1: Using SecureString for SPN Secret and specifying TenantId
param(
    [string]$SpnId = "",
    [securestring]$SpnSecret = "",
    [string]$TenantId = ""
)

# Option #2: Using SecureString for SPN Secret and not specifying TenantId (defaults to home tenant)
param(
    [string]$SpnId = "",
    [securestring]$SpnSecret = "",
)

# Option #3: Retrieving "SPNSECRET" from Azure Key Vault and not specifying TenantId (defaults to home tenant)
param(
    [string]$SpnId = "",
    [string]$keyVaultName = ""
)
# Note: Requires User Azure RBAC permissions to access the Key Vault and retrieve secrets. (Key Vault Secrets User)

# Option #4: Retrieving "SPNSECRET" from Azure Key Vault and specifying TenantId
param(
    [string]$SpnId = "",
    [string]$TenantId = "",
    [string]$keyVaultName = ""
)


# Example Code Snippets

# 1. Connect to Microsoft Defender for Endpoint and get a token
$token = Connect-MDE -SpnId $SpnId -SpnSecret $SpnSecret -TenantId $TenantId

# 2. Upload a file to the Live Response library (limit: 250 MB)
Invoke-UploadLR -token $token -filePath "C:\MDEAutomator\tester.txt"

# 3. Push a Live Response Library file to endpoint devices
Invoke-PutFile -token $token -fileName "Active.ps1" -DeviceIds @("04692ea0870a250b15d6cfebef637911cd34c01d")

# 4. Run a full disk scan on multiple devices
Invoke-FullDiskScan -token $token -DeviceIds @(
    "04692ea0870a250b15d6cfebef637911cd34c01d",
    "12345abcde67890fghij1234567890klmnopqrs"
)

# 5. Get a file from a device
Invoke-GetFile -token $token -filePath "C:\Windows\Temp\log.txt" -DeviceIds @("04692ea0870a250b15d6cfebef637911cd34c01d")

# 6. Collect an investigation package and upload to a storage account
Invoke-CollectInvestigationPackage -token $token -DeviceIds @("04692ea0870a250b15d6cfebef637911cd34c01d") -StorageAccountName "yourstorageaccount"

# 7. Run a script via Live Response
Invoke-LRScript -token $token -DeviceIds @("04692ea0870a250b15d6cfebef637911cd34c01d") -scriptName "Active.ps1"

# 8. Get all onboarded and active Windows machines
Get-Machines -token $token -filter "contains(osPlatform, 'Windows')"

# 9. Get recent machine actions (last 90 days)
Get-Actions -token $token

# 10. Cancel all current pending machine actions
Undo-Actions -token $token

# 11. Isolate endpoints from the network
Invoke-MachineIsolation -token $token -DeviceIds @("04692ea0870a250b15d6cfebef637911cd34c01d")

# 12. Release endpoints from isolation
Undo-MachineIsolation -token $token -DeviceIds @("04692ea0870a250b15d6cfebef637911cd34c01d")

# 13. Restrict application/code execution on a device
Invoke-RestrictAppExecution -token $token -DeviceIds 04692ea0870a250b15d6cfebef637911cd34c01d

# 14. Remove application/code execution restriction
Undo-RestrictAppExecution -token $token -DeviceIds @("04692ea0870a250b15d6cfebef637911cd34c01d")

# 15. Block a file hash (SHA256) as a custom threat indicator
Invoke-TiFile -token $token -Sha256s @("e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3")

# 16. Remove a file hash threat indicator
Undo-TiFile -token $token -Sha256s @("e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3")

# 17. Block an IP address as a threat indicator
Invoke-TiIP -token $token -IPs @("208.59.28.21")

# 18. Remove an IP address threat indicator
Undo-TiIP -token $token -IPs @("208.59.28.21")

# 19. Block a domain or URL as a threat indicator
Invoke-TiURL -token $token -URLs @("malicious.example.com")

# 20. Remove a domain or URL threat indicator
Undo-TiURL -token $token -URLs @("malicious.example.com")

# 21. Block a certificate thumbprint as a threat indicator
Invoke-TiCert -token $token -Sha1s @("abcdef1234567890abcdef1234567890abcdef12")

# 22. Remove a certificate thumbprint threat indicator
Undo-TiCert -token $token -Sha1s @("abcdef1234567890abcdef1234567890abcdef12")

# 23. Offboard a device from Defender for Endpoint
Invoke-MachineOffboard -token $token -DeviceIds @("04692ea0870a250b15d6cfebef637911cd34c01d")

# 24. Download a file from a device and save locally
$downloadUrl = Invoke-GetFile -token $token -filePath "C:\Windows\Temp\log.txt" -DeviceIds @("04692ea0870a250b15d6cfebef637911cd34c01d")
Invoke-WebRequest -Uri $downloadUrl -OutFile "C:\Temp\log.txt"

