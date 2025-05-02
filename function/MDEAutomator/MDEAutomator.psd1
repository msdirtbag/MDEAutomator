@{
    # Module Identity
    ModuleVersion     = '1.0'
    GUID              = '010c4ef2-f71c-4bce-84cc-de9752cf1577'
    RootModule        = 'MDEAutomator.psm1'

    # Module Info
    Author            = 'msdirtbag'
    Copyright         = '(c) All Rights Reserved.'
    Description       = 'Microsoft Defender for Endpoint Automation Module'
    PowerShellVersion = '7.4'

    # Export Settings
    FunctionsToExport = @(
        # Authentication & Utility
        'Connect-MDE'
        'Get-AccessToken'
        'Get-RequestParam'
        'Invoke-WithRetry'
        'Get-SecretFromKeyVault'

        # Core Operations
        'Get-Machines'
        'Get-Actions'
        'Undo-Actions'
        'Get-MachineActionStatus'
        
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
        'Invoke-CollectInvestigationPackage'

        # IOC's
        'Invoke-TiFile', 'Undo-TiFile'
        'Invoke-TiCert', 'Undo-TiCert'
        'Invoke-TiIP',   'Undo-TiIP'
        'Invoke-TiURL',  'Undo-TiURL'
    )
}