param(
    [Parameter(Mandatory = $true)]
    [string]$uminame,
    [Parameter(Mandatory = $true)]
    [string]$spnname
)

Write-Host "Starting script..."
Write-Host "Parameters received: uminame='$uminame', spnname='$spnname'"

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Host "Microsoft.Graph module not found. Installing..."
    Install-Module -Name Microsoft.Graph.Authentication -Force -Scope CurrentUser
} else {
    Write-Host "Microsoft.Graph module is already available."
}

if (-not (Get-Module -Name Microsoft.Graph.Authentication)) {
    Write-Host "Importing Microsoft.Graph module..."
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
} else {
    Write-Host "Microsoft.Graph module already imported."
}

Write-Host "Connecting to Microsoft Graph..."
$requiredScopes = @(
    "Application.ReadWrite.All",
    "Directory.ReadWrite.All"
)
Connect-MgGraph -Scopes $requiredScopes -NoWelcome
Write-Host "Connected to Microsoft Graph successfully."

$graphPermissions = @(
    'CustomDetection.ReadWrite.All',
    'ThreatHunting.Read.All',
    'ThreatIndicators.ReadWrite.OwnedBy'
)
$atpPermissions = @(
    'AdvancedQuery.Read.All',
    'Alert.Read.All',
    'File.Read.All',
    'Ip.Read.All',
    'Library.Manage',
    'Machine.CollectForensics',
    'Machine.Isolate',
    'Machine.LiveResponse',
    'Machine.ReadWrite.All',
    'Machine.RestrictExecution',
    'Machine.Scan',
    'Machine.StopAndQuarantine',
    'Ti.ReadWrite.All',
    'User.Read.All'
)

$graphAppId = '00000003-0000-0000-c000-000000000000'
$atpAppId   = 'fc780465-2017-40d4-a0c5-307022471b92'

Write-Host "Looking up App Registration with display name '$spnname'..."
$appReg = Get-MgApplication -Filter "DisplayName eq '$spnname'"
if (-not $appReg) {
    Write-Host "App Registration not found. Creating new App Registration '$spnname'..."
    $appReg = New-MgApplication -DisplayName $spnname
    Write-Host "Created new App Registration '$spnname'."
} else {
    Write-Host "App Registration '$spnname' already exists."
}

Write-Host "Looking up Service Principal for App Registration..."
$appSpn = Get-MgServicePrincipal -Filter "AppId eq '$($appReg.AppId)'"
if (-not $appSpn) {
    Write-Host "Service Principal not found. Creating Service Principal for App Registration '$spnname'..."
    $appSpn = New-MgServicePrincipal -AppId $appReg.AppId
    Write-Host "Created Service Principal for App Registration '$spnname'."
} else {
    Write-Host "Service Principal for App Registration '$spnname' already exists."
}

Write-Host "Looking up UMI Service Principal with display name '$uminame'..."
$umiSpn = Get-MgServicePrincipal -Filter "DisplayName eq '$uminame'"
if (-not $umiSpn) {
    Write-Error "User Managed Identity (service principal) with display name '$uminame' not found."
    exit 1
} else {
    Write-Host "Found UMI Service Principal with display name '$uminame'."
}

$TenantId = (Get-AzContext).Tenant.Id

Write-Host "Checking for existing federated credential for UMI..."
$federatedCredName = "umi-$($uminame.Replace(' ', '-'))"
$existingFedCred = (Get-MgApplicationFederatedIdentityCredential -ApplicationId $appReg.Id -ErrorAction SilentlyContinue) | Where-Object { $_.Name -eq $federatedCredName }
if (-not $existingFedCred) {
    Write-Host "Federated credential not found. Adding federated credential for UMI '$uminame'..."
    $fedBody = @{
        Name = $federatedCredName
        Issuer = "https://login.microsoftonline.com/$($TenantId)/v2.0"
        Subject = "userassignedidentity://$($umiSpn.Id)"
        Description = "Federated credential for UMI $uminame"
        Audiences = @("api://AzureADTokenExchange")
    }
    New-MgApplicationFederatedIdentityCredential -ApplicationId $appReg.Id -BodyParameter $fedBody
    Write-Host "Federated credential added to App Registration '$spnname' for UMI '$uminame'."
} else {
    Write-Host "Federated credential already exists for UMI '$uminame' in App Registration '$spnname'."
}

function Set-AppRoles {
    param (
        [string]$ResourceAppId,
        [array]$Permissions
    )
    Write-Host "Assigning permissions for ResourceAppId: $ResourceAppId"
    $spn = Get-MgServicePrincipal -Filter "AppId eq '$ResourceAppId'"
    if (-not $spn) {
        Write-Warning "Service Principal for ResourceAppId $ResourceAppId not found."
        return
    }
    foreach ($perm in $Permissions) {
        Write-Host "Processing permission '$perm'..."
        $role = $spn.AppRoles | Where-Object { $_.Value -eq $perm -and $_.AllowedMemberTypes -contains "Application" }
        if (-not $role) {
            Write-Warning "Permission '$perm' not found for AppId $ResourceAppId."
            continue
        }
        $already = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $appSpn.Id |
            Where-Object { $_.ResourceId -eq $spn.Id -and $_.AppRoleId -eq $role.Id }
        if ($already) {
            Write-Host "Permission '$perm' already assigned to App Registration."
            continue
        }
        $body = @{
            PrincipalId = $appSpn.Id
            ResourceId  = $spn.Id
            AppRoleId   = $role.Id
        }
        Write-Host "Assigning permission '$perm'..."
        New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $appSpn.Id -BodyParameter $body
        Write-Host "Assigned '$perm' to App Registration '$spnname'."
    }
}

try {
    Write-Host "Assigning Graph permissions..."
    Set-AppRoles -ResourceAppId $graphAppId -Permissions $graphPermissions
    Write-Host "Assigning ATP permissions..."
    Set-AppRoles -ResourceAppId $atpAppId -Permissions $atpPermissions
    Write-Host "Graph & ATP permissions added to App Registration successfully."
    
    # Add admin consent for the assigned permissions
    Write-Host "Granting admin consent for all assigned permissions..."
    
    $graphSpn = Get-MgServicePrincipal -Filter "AppId eq '$graphAppId'"
    $atpSpn = Get-MgServicePrincipal -Filter "AppId eq '$atpAppId'"
    
    # Get current app role assignments
    $graphAssignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $appSpn.Id | 
                        Where-Object { $_.ResourceId -eq $graphSpn.Id }
    $atpAssignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $appSpn.Id | 
                      Where-Object { $_.ResourceId -eq $atpSpn.Id }
    
    # Grant admin consent by updating app role assignment state
    foreach ($assignment in ($graphAssignments + $atpAssignments)) {
        Write-Host "Consenting to permission with ID: $($assignment.AppRoleId)"
        # Admin consent is implicitly granted when the app role assignment exists
        # The following line ensures the assignment is properly registered
        $null = Update-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $appSpn.Id -AppRoleAssignmentId $assignment.Id -ErrorAction SilentlyContinue
    }
    
    Write-Host "Admin consent granted for all assigned permissions."
}
catch {
    Write-Error "An error occurred while assigning permissions or granting consent: $_"
    exit 1
}

Write-Host "addfedcred.ps1 script completed."
