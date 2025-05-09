@{
    # Module Identity
    ModuleVersion     = '1.5.0'
    GUID              = '010c4ef2-f71c-4bce-84cc-de9752cf1577'
    RootModule        = 'MDEAutomator.psm1'

    # Module Info
    Author            = 'msdirtbag'
    Copyright         = '(c) All Rights Reserved.'
    Description       = 'Microsoft Defender for Endpoint Automation Module'
    PowerShellVersion = '5.1'

    # Export Settings
    FunctionsToExport = @(
        # Authentication & Utility
        'Connect-MDE'
        'Connect-MDEGraph'
        'Get-AccessToken'
        'Get-RequestParam'
        'Invoke-WithRetry'
        'Get-SecretFromKeyVault'

        # Core Operations
        'Get-Machines'
        'Get-Actions'
        'Undo-Actions'
        'Get-IPInfo'
        'Get-FileInfo'
        'Get-LoggedInUsers'
        'Get-MachineActionStatus'
        'Invoke-AdvancedHunting'
        
        # Live Response Actions
        'Invoke-UploadLR'
        'Invoke-PutFile'
        'Invoke-GetFile'
        'Invoke-LRScript'
        'Get-LiveResponseOutput'

        # Response Actions
        'Invoke-MachineIsolation', 'Undo-MachineIsolation'
        'Invoke-ContainDevice', 'Undo-ContainDevice'
        'Invoke-RestrictAppExecution', 'Undo-RestrictAppExecution'
        'Invoke-FullDiskScan'
        'Invoke-StopAndQuarantineFile'
        'Invoke-CollectInvestigationPackage'

        # IOC's
        'Get-Indicators',
        'Invoke-TiFile', 'Undo-TiFile'
        'Invoke-TiCert', 'Undo-TiCert'
        'Invoke-TiIP',   'Undo-TiIP'
        'Invoke-TiURL',  'Undo-TiURL'
    )
}