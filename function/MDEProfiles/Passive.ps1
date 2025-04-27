# =============================================================================================================================================================== #
#                                                               Passive Protection Configuration Script                                                        #
# =============================================================================================================================================================== #

#Core Settings
Set-MpPreference -DisableBehaviorMonitoring $False -Force
Set-MpPreference -MAPSReporting Advanced -Force
Set-MpPreference -SubmitSamplesConsent SendAllSamples -Force
Set-MpPreference -DisableRealtimeMonitoring $true -Force
Set-MpPreference -EnableLowCpuPriority $true -Force

#EDR Service
Set-Service diagtrack -startuptype automatic

#Network Protection
Set-MpPreference -EnableNetworkProtection AuditMode -Force
Set-MpPreference -AllowNetworkProtectionOnWinServer 1 -Force
Set-MpPreference -AllowNetworkProtectionDownLevel 1 -Force
Set-MpPreference -AllowSwitchToAsyncInspection $true -Force

#Windows Firewall
Auditpol /set /category:"System" /subcategory:"Filtering Platform Packet Drop" /success:enable /failure:enable | Out-Null
Auditpol /set /category:"System" /subcategory:"Filtering Platform Connection" /success:enable /failure:enable | Out-Null

#Advanced Settings
Set-MpPreference -DisableScriptScanning $False -Force
Set-MpPreference -EnableFileHashComputation $true -Force
Set-MpPreference -EnableControlledFolderAccess AuditMode -Force

#Signature Update Settings
Set-MpPreference -SignatureScheduleDay Everyday -Force
Set-MpPreference -RandomizeScheduleTaskTime $True -Force

#PUA Detection
Set-MpPreference -PUAProtection AuditMode -Force

# ============================================================================================================================================================= #
#                                                                  Attack Surface Reduction Rules                                                               #
# ============================================================================================================================================================= #

$ASRAction = "AuditMode"
$ASRGUIDS = @(
    "75668C1F-73B5-4CF0-BB93-3ECF5CB7CC84",
    "3B576869-A4EC-4529-8536-B80A7769E899",
    "D4F940AB-401B-4EfC-AADC-AD5F3C50688A",
    "D3E037E1-3EB8-44C8-A917-57927947596D",
    "5BEB7EFE-FD9A-4556-801D-275E5FFC04CC",
    "BE9BA2D9-53EA-4CDC-84E5-9B1EEEE46550",
    "92E97FA1-2EDF-4476-BDD6-9DD0B4DDDC7B",
    "D1E49AAC-8F56-4280-B9BA-993A6D77406C",
    "B2B3F03D-6A65-4F7B-A9C7-1C7EF74A9BA4",
    "C1DB55AB-C21A-4637-BB3F-A12568109D35",
    "56a863a9-875e-4185-98a7-b882c64b5ce5",
    "7674ba52-37eb-4a4f-a9a1-f0f9a1619a2c",
    "9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2",
    "26190899-1602-49e8-8b27-eb1d0a1ce869",
    "e6db77e5-3df2-4cf1-b95a-636979351e5b",
    "c1db55ab-c21a-4637-bb3f-a12568109d35",
    "c0033c00-d16d-4114-a5a0-dc9b3a7d2ceb",
    "a8f5898e-1dc8-49a9-9878-85004b8a61e6",
    "33ddedf1-c6e0-47cb-833e-de6133960387",
    "01443614-CD74-433A-B99E-2ECDC07BFC25"
)

foreach ($ASRGUID in $ASRGUIDS) {
    Set-MpPreference -AttackSurfaceReductionRules_Ids $ASRGUID -AttackSurfaceReductionRules_Actions $ASRAction -Force
}

# =========================================================================================================== #
#                                               MDE Device Tag                                                #
# =========================================================================================================== #

$registryPath = "HKLM:SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection\DeviceTagging"
$Name = "Group"
$value = "Passive"

IF(!(Test-Path $registryPath))
  {
    New-Item -Path $registryPath -Force | Out-Null
    New-ItemProperty -Path $registryPath -Name $name -Value $value -PropertyType String -Force | Out-Null}
 ELSE {
    New-ItemProperty -Path $registryPath -Name $name -Value $value -PropertyType string -Force | Out-Null}

# =========================================================================================================== #
#                                               Confirmation                                                  #
# =========================================================================================================== #
$hostname = hostname
Write-Host "Passive was successfully configured on $hostname."
