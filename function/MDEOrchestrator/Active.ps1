# =============================================================================================================================================================== #
#                                                               Active Protection Configuration Script                                                        #
# =============================================================================================================================================================== #

#Core Settings
Set-MpPreference -DisableBehaviorMonitoring $False -Force
Set-MpPreference -MAPSReporting Advanced -Force
Set-MpPreference -SubmitSamplesConsent SendAllSamples -Force
Set-MpPreference -DisableRealtimeMonitoring $False -Force
Set-MpPreference -CloudBlockLevel HighPlus -Force
Set-MpPreference -EnableLowCpuPriority $true -Force

#EDR Service
Set-Service diagtrack -startuptype automatic

#Network Protection
Set-MpPreference -EnableNetworkProtection Enabled -Force
Set-MpPreference -AllowNetworkProtectionOnWinServer 1 -Force
Set-MpPreference -AllowNetworkProtectionDownLevel 1 -Force
Set-MpPreference -DisableTlsParsing $False -Force
Set-MpPreference -AllowDatagramProcessingOnWinServer 1 -Force
Set-MpPreference -AllowSwitchToAsyncInspection $true -Force

#Windows Firewall
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True
Auditpol /set /category:"System" /subcategory:"Filtering Platform Packet Drop" /success:enable /failure:enable | Out-Null
Auditpol /set /category:"System" /subcategory:"Filtering Platform Connection" /success:enable /failure:enable | Out-Null

#Advanced Settings
Set-MpPreference -DisableRemovableDriveScanning $False -Force
Set-MpPreference -DisableScriptScanning $False -Force
Set-MpPreference -DisableIOAVProtection $False -Force
Set-MpPreference -DisableBlockAtFirstSeen $False -Force
Set-MpPreference -DisableEmailScanning $False -Force
Set-MpPreference -EnableFileHashComputation $true -Force
Set-MpPreference -RealTimeScanDirection 0 -Force
Set-MpPreference -UnknownThreatDefaultAction Quarantine -Force

#Signature Update Settings
Set-MpPreference -SignatureScheduleDay Everyday -Force
Set-MpPreference -CheckForSignaturesBeforeRunningScan $True -Force
Set-MpPreference -RandomizeScheduleTaskTime $True -Force

#PUA Detection
Set-MpPreference -PUAProtection AuditMode -Force

# =========================================================================================================== #
#                                               MDE Device Tag                                                #
# =========================================================================================================== #

$registryPath = "HKLM:SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection\DeviceTagging"
$Name = "Group"
$value = "Active"

IF(!(Test-Path $registryPath))
  {
    New-Item -Path $registryPath -Force | Out-Null
    New-ItemProperty -Path $registryPath -Name $name -Value $value -PropertyType String -Force | Out-Null}
 ELSE {
    New-ItemProperty -Path $registryPath -Name $name -Value $value -PropertyType string -Force | Out-Null}

# ================================================================================================================================== #
#                                       Attack Surface Reduction Rules                                                               #
# ================================================================================================================================== #

$ASRAction = "Enabled"
$ASRGUIDS = @(
    "75668C1F-73B5-4CF0-BB93-3ECF5CB7CC84",
    "3B576869-A4EC-4529-8536-B80A7769E899",
    "D4F940AB-401B-4EFC-AADC-AD5F3C50688A",
    "D3E037E1-3EB8-44C8-A917-57927947596D",
    "5BEB7EFE-FD9A-4556-801D-275E5FFC04CC",
    "BE9BA2D9-53EA-4CDC-84E5-9B1EEEE46550",
    "92E97FA1-2EDF-4476-BDD6-9DD0B4DDDC7B",
    "D1E49AAC-8F56-4280-B9BA-993A6D77406C",
    "B2B3F03D-6A65-4F7B-A9C7-1C7EF74A9BA4",
    "C1DB55AB-C21A-4637-BB3F-A12568109D35",
    "56A863A9-875E-4185-98A7-B882C64B5CE5",
    "7674BA52-37EB-4A4F-A9A1-F0F9A1619A2C",
    "9E6C4E1F-7D60-472F-BA1A-A39EF669E4B2",
    "26190899-1602-49E8-8B27-EB1D0A1CE869",
    "E6DB77E5-3DF2-4CF1-B95A-636979351E5B",
    "C0033C00-D16D-4114-A5A0-DC9B3A7D2CEB",
    "A8F5898E-1DC8-49A9-9878-85004B8A61E6",
    "33DDEDF1-C6E0-47CB-833E-DE6133960387",
    "01443614-CD74-433A-B99E-2ECDC07BFC25"
)

foreach ($ASRGUID in $ASRGUIDS) {
    if ($ASRGUID -eq "33DDEDF1-C6E0-47CB-833E-DE6133960387" -or $ASRGUID -eq "01443614-CD74-433A-B99E-2ECDC07BFC25" -or $ASRGUID -eq "d1e49aac-8f56-4280-b9ba-993a6d77406c") {
        Set-MpPreference -AttackSurfaceReductionRules_Ids $ASRGUID -AttackSurfaceReductionRules_Actions "AuditMode" -Force
    } else {
        Set-MpPreference -AttackSurfaceReductionRules_Ids $ASRGUID -AttackSurfaceReductionRules_Actions $ASRAction -Force
    }
}

# Registry Settings
try {
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name "DisableRestrictedAdmin" -Value 0 -Force
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name "restrictanonymoussam" -Value 1 -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "ConsentPromptBehaviorUser" -Value 0 -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" -Name "NoAutorun" -Value 1 -Force
} catch {
    $errorMessage = "An error occurred: $_"
    Write-Host $errorMessage
    Write-Host "Failed setting: $($_.InvocationInfo.MyCommand)"
} finally {
    Write-Host "Registry Settings configured successfully."
}

# =========================================================================================================== #
#                                                   WDAC                                                      #
# =========================================================================================================== #

$guid = "{A244370E-44C9-4C06-00FF-F6016E563076}"
$WDACcipurl = "https://github.com/msdirtbag/MDEAutomator/blob/main/payloads/%7BA244370E-44C9-4C06-00FF-F6016E563076%7D.cip"
$DestinationFolder = "C:\Windows\System32\CodeIntegrity\CIPolicies\Active\"
$DestinationFilePath = "$DestinationFolder\$guid.cip"

if (Test-Path $DestinationFilePath) {
    Write-Host "WDAC has already been deployed."
} else {
    try {
        Invoke-WebRequest -Uri $WDACcipurl -OutFile $DestinationFilePath
        Write-Host "Deployed WDAC"
    } catch {
        Write-Error "An error occurred: $_"
    }
}

# =========================================================================================================== #
#                                             Exploit Protection                                              #
# =========================================================================================================== #
# Continue if Windows 10 or 11
$osVersion = (Get-WmiObject -Class Win32_OperatingSystem).Version
if ($osVersion -like "10.*" -or $osVersion -like "11.*") {   
$file_url = "https://github.com/msdirtbag/MDEAutomator/blob/main/payloads/XploitProtection.xml"
$file_path = "C:\Users\Public\XploitProtection.xml"
$directory_path = [System.IO.Path]::GetDirectoryName($file_path)

if (-not (Test-Path $directory_path)) {
    New-Item -ItemType Directory -Path $directory_path -Force
}

if (Test-Path $file_path) {
    Write-Host "Exploit Protection has already been deployed."
} else {
    Invoke-WebRequest -Uri $file_url -OutFile $file_path
    Set-ProcessMitigation -PolicyFilePath $file_path
    Write-Host "Deployed Exploit Protection"
}
}

# =========================================================================================================== #
#                                               Confirmation                                                  #
# =========================================================================================================== #

$hostname = hostname
Write-Host "Active was successfully configured on $hostname."
