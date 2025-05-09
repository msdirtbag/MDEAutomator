<#
.SYNOPSIS
    MDEAutomator PowerShell Module - Automates Microsoft Defender for Endpoint (MDE) API operations.

.DESCRIPTION
    This module provides a set of functions to automate common Microsoft Defender for Endpoint (MDE) tasks via the MDE API, including device management, live response actions, threat indicator management, and more. It supports robust error handling, retry logic, and integration with Azure Key Vault for secure secret management.

.FUNCTIONS
    Connect-MDE
        Authenticates to MDE using a Service Principal, optionally retrieving secrets from Azure Key Vault.

    Get-Machines
        Retrieves a list of onboarded and active devices from MDE, with optional filtering.

    Get-Actions
        Retrieves recent machine actions performed in MDE.

    Undo-Actions
        Cancels all pending machine actions in MDE.

    Invoke-MachineIsolation / Undo-MachineIsolation
        Isolates or unisolates specified devices in MDE.

    Invoke-ContainDevice / Undo-ContainDevice
        Contains or uncontains specified unmanaged devices in MDE.

    Invoke-RestrictAppExecution / Undo-RestrictAppExecution
        Restricts or unrestricts application execution on specified devices.
        
    Invoke-CollectInvestigationPackage
        Collects an investigation package from specified devices.

    Invoke-TiFile / Undo-TiFile
        Creates or deletes file hash-based custom threat indicators.

    Invoke-TiCert / Undo-TiCert
        Creates or deletes certificate thumbprint-based custom threat indicators.

    Invoke-TiIP / Undo-TiIP
        Creates or deletes IP address-based custom threat indicators.

    Invoke-TiURL / Undo-TiURL
        Creates or deletes URL/domain-based custom threat indicators.

    Invoke-UploadLR
        Uploads a script file to the MDE Live Response library.

    Invoke-PutFile
        Pushes a file from the Live Response library to specified devices.

    Invoke-GetFile
        Retrieves a file from specified devices using Live Response.

    Invoke-LRScript
        Executes a Live Response script on specified devices.

.PARAMETERS
    Most functions require an OAuth2 access token (`$token`) obtained via Connect-MDE.
    Device-specific functions require one or more device IDs (`$DeviceIds`).
    Threat indicator functions require indicator values (e.g., `$Sha1s`, `$Sha256s`, `$IPs`, `$URLs`).

.NOTES
    - Requires PowerShell 5.1+ and the Az.Accounts/Az.KeyVault modules for Key Vault integration.
    - All API calls are made to the Microsoft Defender for Endpoint API (https://api.securitycenter.microsoft.com).
    - Error handling and retry logic are built-in for robust automation.
    - For more information, see the official Microsoft Defender for Endpoint API documentation.

.AUTHOR
    github.com/msdirtbag

.VERSION
    1.0.0

#>

Function Get-RequestParam {
    param (
        [string]$Name,
        [PSCustomObject]$Request
    )
    $value = $Request.Query.$Name
    if (-not $value) {
        $value = $Request.Body.$Name
    }
    return $value
}

function Get-SecretFromKeyVault {
    param (
        [Parameter(Mandatory = $true)]
        [string] $keyVaultName
    )

    $secretValue = (Get-AzKeyVaultSecret -VaultName $keyVaultName -Name "SPNSECRET" -WarningAction SilentlyContinue).SecretValue

    if ($null -eq $secretValue) {
        throw "[ERROR] Secret not found in Key Vault '$keyVaultName'"
    }

    return $secretValue
}

function Get-AccessToken {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantId,
        [Parameter(Mandatory = $true)]
        [string]$SpnId,
        [Parameter(Mandatory = $true)]
        [string]$SpnSecret
    )

    $resourceAppIdUri = 'https://api.securitycenter.microsoft.com'
    $oAuthUri = "https://login.microsoftonline.com/$TenantId/oauth2/token"
    $body = [Ordered]@{
        resource      = $resourceAppIdUri
        client_id     = $SpnId
        client_secret = $SpnSecret
        grant_type    = 'client_credentials'
    }

    try {
        $response = Invoke-RestMethod -Method Post -Uri $oAuthUri -Body $body -ErrorAction Stop
        return $response.access_token
    } catch {
        Write-Error "Failed to acquire access token: $_"
        exit 1
    }
}

Function Connect-MDE {
    param (
        [Parameter(Mandatory=$false)]
        [string] $keyVaultName,
        [Parameter(Mandatory=$true)]
        [string] $SpnId,
        [Parameter(Mandatory=$false)]
        [securestring] $SpnSecret,
        [Parameter(Mandatory=$false)]
        [string] $TenantId
    )
    Write-Host "Connecting to MDE (this may take a few minutes)"

    if (-not $TenantId) {
        $TenantId = (Get-AzContext).Tenant.Id
    }

    if (-not $SpnSecret) {
        if ($keyVaultName) {
            if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
                Write-Host "Az.Accounts module not found. Installing for first use..."
                Install-Module -Name Az.Accounts -Scope CurrentUser -Force -AllowClobber
            }
            if (-not (Get-Module -ListAvailable -Name Az.KeyVault)) {
                Write-Host "Az.KeyVault module not found. Installing for first use..."
                Install-Module -Name Az.KeyVault -Scope CurrentUser -Force -AllowClobber
            }
            if (-not (Get-Module -Name Az.Accounts)) {
                Import-Module Az.Accounts -ErrorAction Stop
            }
            if (-not (Get-Module -Name Az.KeyVault)) {
                Import-Module Az.KeyVault -ErrorAction Stop
            }
            if (-not (Get-AzContext)) {
                Write-Host "No Azure session detected. Please sign in."
                Connect-AzAccount -TenantId $TenantId -ErrorAction Stop
            }
            $SpnSecret = (Get-AzKeyVaultSecret -VaultName $keyVaultName -Name 'SPNSECRET').SecretValue
        } else {
            Write-Error "SpnSecret must be provided if keyVaultName is not specified."
            throw "SpnSecret must be provided if keyVaultName is not specified."
        }
    }

    if (-not $SpnSecret) {
        Write-Error "Failed to retrieve SPN secret"
        throw "Failed to retrieve SPN secret"
    }

    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SpnSecret)
    $plainSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)

    try {
        $token = Get-AccessToken -TenantId $TenantId -SpnId $SpnId -SpnSecret $plainSecret
        Write-Host "Successfully retrieved access token for MDE."
    } catch {
        Write-Host "Failed to retrieve access token for MDE. Error: $_"
        exit 1
    }
    return $token
}
Function Connect-MDEGraph {
    param (
        [Parameter(Mandatory = $false)]
        [string] $keyVaultName,
        [Parameter(Mandatory = $true)]
        [string] $SpnId,
        [Parameter(Mandatory = $false)]
        [securestring] $SpnSecret,
        [Parameter(Mandatory = $false)]
        [string] $TenantId
    )

    if (-not $TenantId) {
        $TenantId = (Get-AzContext).Tenant.Id
    }

    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        Write-Host "Az.Accounts module not found. Installing for first use..."
        Install-Module -Name Az.Accounts -Scope CurrentUser -Force -AllowClobber
    }
    if (-not (Get-Module -ListAvailable -Name Az.KeyVault)) {
        Write-Host "Az.KeyVault module not found. Installing for first use..."
        Install-Module -Name Az.KeyVault -Scope CurrentUser -Force -AllowClobber
    }
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        Write-Host "Microsoft.Graph module not found. Installing for first use..."
        Install-Module -Name Microsoft.Graph -Scope CurrentUser -Force -AllowClobber
    }
    if (-not (Get-Module -Name Az.Accounts)) {
        Import-Module Az.Accounts -ErrorAction Stop
    }
    if (-not (Get-Module -Name Az.KeyVault)) {
        Import-Module Az.KeyVault -ErrorAction Stop
    }
    if (-not (Get-Module -Name Microsoft.Graph.Authentication)) {
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    }

    if (-not $SpnSecret) {
        if ($keyVaultName) {
            if (-not (Get-AzContext)) {
                Write-Host "No Azure session detected. Please sign in."
                Connect-AzAccount -TenantId $TenantId -ErrorAction Stop
            }
            $SpnSecret = (Get-AzKeyVaultSecret -VaultName $keyVaultName -Name 'SPNSECRET').SecretValue
        } else {
            Write-Error "SpnSecret must be provided if keyVaultName is not specified."
            throw "SpnSecret must be provided if keyVaultName is not specified."
        }
    }

    if (-not $SpnSecret) {
        Write-Error "Failed to retrieve SPN secret"
        throw "Failed to retrieve SPN secret"
    }

    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SpnSecret)
    $plainSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)

    try {
        $SecuredPassword = ConvertTo-SecureString -String $plainSecret -AsPlainText -Force
        $ClientSecretCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $SpnId, $SecuredPassword
        Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $ClientSecretCredential | Out-Null
        Write-Host "Successfully connected to Microsoft Graph."
    } catch {
        Write-Host "Failed to connect to Microsoft Graph. Error: $_"
        exit 1
    }
}
function Invoke-WithRetry {
    param(
        [Parameter(Mandatory=$true)]
        [scriptblock]$ScriptBlock,
        [Parameter(Mandatory=$false)]
        [int]$MaxRetryCount = 5,
        [Parameter(Mandatory=$false)]
        [int]$InitialDelaySeconds = 20,
        [Parameter(Mandatory=$false)]
        [bool]$AllowNullResponse = $false,
        [Parameter(Mandatory=$false)]
        [object[]]$ScriptBlockArgs = @()
    )

    $retryCount = 0
    $currentDelaySeconds = $InitialDelaySeconds

    do {
        try {
            $response = & $ScriptBlock @ScriptBlockArgs
            if ($null -eq $response -and -not $AllowNullResponse) {
                Write-Error "Error: Response is null"
                throw "Response is null"
            }
            return $response
        } catch {
            $exception = $_
            $statusCode = $exception.Exception.Response?.StatusCode
            $errorMsg = $exception.Exception.Message
            $errorContent = $exception.Exception.Response?.Error
            if ($errorContent) {
                try {
                    $errorJson = $errorContent | ConvertFrom-Json
                    if ($errorJson.error.code -eq "ActiveRequestAlreadyExists") {
                        Write-Warning "Active request already exists. Skipping. Message: $($errorJson.error.message)"
                        return [PSCustomObject]@{
                            Status = "Skipped"
                            StatusCode = $statusCode
                            ErrorCode = $errorJson.error.code
                            Message = $errorJson.error.message
                        }
                    }
                } catch {
                    Write-Warning "Failed to parse error content: $errorContent"
                }
            }

            if ($statusCode -eq 429) {
                $retryAfter = $exception.Exception.Response.Headers["Retry-After"]
                $currentDelaySeconds = if ($retryAfter -and [int]::TryParse($retryAfter, [ref]$parsedRetryAfter)) {
                    $parsedRetryAfter
                } else {
                    60
                }
                Write-Warning "Rate limit exceeded. Waiting $currentDelaySeconds seconds before retrying..."
            } elseif ($statusCode -ge 400 -and $statusCode -lt 500) {
                if ($statusCode -ne 429) {
                    Write-Warning "MDE says endpoint is unavailable"
                    return [PSCustomObject]@{
                        Status = "Skipped"
                        StatusCode = $statusCode
                        Message = $errorMsg
                    }
                }
            } elseif (($statusCode -ge 500 -and $statusCode -lt 600) -or ($null -eq $statusCode)) {
                Write-Warning "Server error or null response encountered. Retrying..."
            } else {
                Write-Error "Non-HTTP exception encountered: $errorMsg"
            }

            if ($retryCount -ge $MaxRetryCount) {
                Write-Error "Max retry count ($MaxRetryCount) reached. Aborting."
                throw "Max retry attempts reached."
            }

            Start-Sleep -Seconds $currentDelaySeconds
            $retryCount++
            $currentDelaySeconds = [Math]::Min($currentDelaySeconds * 2, 600) + (Get-Random -Minimum 2 -Maximum 5)
        }
    } while ($true)
}

function Invoke-FullDiskScan {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$DeviceIds
    )
    $headers = @{
        "Authorization" = "Bearer $token"
    }
    $body = @{
        "Comment" = "MDEAutomator"
        "ScanType" = "Full"
    }
    $responses = @()

    foreach ($DeviceId in $DeviceIds) {
        $uri = "https://api.securitycenter.microsoft.com/api/machines/$DeviceId/runAntiVirusScan"
        try {
            $response = Invoke-WithRetry -ScriptBlock {
                Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body ($body | ConvertTo-Json) -ContentType "application/json" -ErrorAction Stop
            }

            $actionId = $response.id
            if ([string]::IsNullOrEmpty($actionId)) {
                Write-Host "No machine action ID received for DeviceId: $DeviceId. Marking as failed and continuing."
                continue
            }
            Start-Sleep -Seconds 5
            $statusSucceeded = Get-MachineActionStatus -machineActionId $actionId -token $token

            if ($statusSucceeded) {
                Write-Host "Started Scan on DeviceId: $DeviceId"
            } else {
                Write-Error "Failed to start Full Scan DeviceId: $DeviceId"
            }

            $responses += [PSCustomObject]@{
                DeviceId = $DeviceId
                Response = [PSCustomObject]@{
                    Id = $response.id
                    Type = $response.type
                    Title = $response.title
                    Requestor = $response.requestor
                    RequestorComment = $response.requestorComment
                    Status = if ($statusSucceeded) { "Succeeded" } else { "Failed" }
                    MachineId = $response.machineId
                    ComputerDnsName = $response.computerDnsName
                    CreationDateTimeUtc = $response.creationDateTimeUtc
                    LastUpdateDateTimeUtc = $response.lastUpdateDateTimeUtc
                    CancellationRequestor = $response.cancellationRequestor
                    CancellationComment = $response.cancellationComment
                    CancellationDateTimeUtc = $response.cancellationDateTimeUtc
                    ErrorHResult = $response.errorHResult
                    Scope = $response.scope
                    ExternalId = $response.externalId
                    RequestSource = $response.requestSource
                    RelatedFileInfo = $response.relatedFileInfo
                    Commands = $response.commands
                    TroubleshootInfo = $response.troubleshootInfo
                }
            }
        } catch {
            Write-Error "Failed to initiate Full Scan for DeviceId: $DeviceId $_"
            $responses += [PSCustomObject]@{
                DeviceId = $DeviceId
                Error = $_.Exception.Message
            }
        }
    }
    return $responses
}

function Invoke-UploadLR {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token,

        [Parameter(Mandatory = $true)]
        [string]$filePath
    )

    try {
        $headers = @{ 
            Authorization = "Bearer $token" 
        }
        $fileName = [System.IO.Path]::GetFileName($filePath)
        $fileContent = [System.IO.File]::ReadAllBytes($filePath)
        $boundary = [System.Guid]::NewGuid().ToString() 
        $LF = "`r`n"
        $memoryStream = New-Object System.IO.MemoryStream
        $fileHeader = [System.Text.Encoding]::UTF8.GetBytes("--$boundary$LF" +
            "Content-Disposition: form-data; name=`"file`"; filename=`"$fileName`"$LF" +
            "Content-Type: application/octet-stream$LF$LF")
        $memoryStream.Write($fileHeader, 0, $fileHeader.Length)
        $memoryStream.Write($fileContent, 0, $fileContent.Length)
        $memoryStream.Write([System.Text.Encoding]::UTF8.GetBytes($LF), 0, 2)
        $parametersDescription = [System.Text.Encoding]::UTF8.GetBytes("--$boundary$LF" +
            "Content-Disposition: form-data; name=`"ParametersDescription`"$LF$LF" +
            "test$LF")
        $memoryStream.Write($parametersDescription, 0, $parametersDescription.Length)
        $hasParameters = [System.Text.Encoding]::UTF8.GetBytes("--$boundary$LF" +
            "Content-Disposition: form-data; name=`"HasParameters`"$LF$LF" +
            "false$LF")
        $memoryStream.Write($hasParameters, 0, $hasParameters.Length)
        $overrideIfExists = [System.Text.Encoding]::UTF8.GetBytes("--$boundary$LF" +
            "Content-Disposition: form-data; name=`"OverrideIfExists`"$LF$LF" +
            "true$LF")
        $memoryStream.Write($overrideIfExists, 0, $overrideIfExists.Length)
        $description = [System.Text.Encoding]::UTF8.GetBytes("--$boundary$LF" +
            "Content-Disposition: form-data; name=`"Description`"$LF$LF" +
            "test description$LF")
        $memoryStream.Write($description, 0, $description.Length)
        $finalBoundary = [System.Text.Encoding]::UTF8.GetBytes("--$boundary--$LF")
        $memoryStream.Write($finalBoundary, 0, $finalBoundary.Length)
        $memoryStream.Seek(0, [System.IO.SeekOrigin]::Begin) | Out-Null
        $bodyBytes = $memoryStream.ToArray()
        Invoke-RestMethod -Uri "https://api.security.microsoft.com/api/libraryfiles" -Method Post -Headers $headers -ContentType "multipart/form-data; boundary=$boundary" -Body $bodyBytes -ErrorAction Stop | Out-Null
        Write-Host "Successfully uploaded file: $fileName"
    } catch {
        if ($_.Exception.Message -notlike "*already exists*") {
            Write-Host "Error uploading script to library: $($_.Exception.Message)"
            exit
        }
    }
}

function Invoke-PutFile {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token,
        [Parameter(Mandatory = $true)]
        [string]$fileName,
        [Parameter(Mandatory = $true)]
        [string[]]$DeviceIds
    )
    $headers = @{
        "Authorization" = "Bearer $token"
    }
    $responses = @()
    foreach ($DeviceId in $DeviceIds) {
        Write-Host "Starting PutFile on DeviceId: $DeviceId"
        $body = @{
            "Commands" = @(
                @{
                    "type" = "PutFile"
                    "params" = @(
                        @{
                            "key" = "FileName"
                            "value" = "$fileName"
                        }
                    )
                }
            )
            "Comment" = "MDEAutomator"
        } | ConvertTo-Json -Depth 10

        try {
            $response = Invoke-WithRetry -ScriptBlock {
                Invoke-RestMethod -Uri "https://api.securitycenter.microsoft.com/api/machines/$DeviceId/runliveresponse" -Method Post -Headers $headers -Body $body -ContentType "application/json" -ErrorAction Stop
            }

            $actionId = $response.id
            if ([string]::IsNullOrEmpty($actionId)) {
                Write-Host "No machine action ID received for DeviceId: $DeviceId. Marking as failed and continuing."
                continue
            }
            Start-Sleep -Seconds 5
            $statusSucceeded = Get-MachineActionStatus -machineActionId $actionId -token $token

            if ($statusSucceeded) {
                Write-Host "PutFile complete on DeviceId: $DeviceId"
            } else {
                Write-Error "PutFile failed on DeviceId: $DeviceId"
            }

            $responses += [PSCustomObject]@{
                DeviceId = $DeviceId
                Response = [PSCustomObject]@{
                    Id = $response.id
                    Type = $response.type
                    Title = $response.title
                    Requestor = $response.requestor
                    RequestorComment = $response.requestorComment
                    Status = $status
                    MachineId = $response.machineId
                    ComputerDnsName = $response.computerDnsName
                    CreationDateTimeUtc = $response.creationDateTimeUtc
                    LastUpdateDateTimeUtc = $response.lastUpdateDateTimeUtc
                    CancellationRequestor = $response.cancellationRequestor
                    CancellationComment = $response.cancellationComment
                    CancellationDateTimeUtc = $response.cancellationDateTimeUtc
                    ErrorHResult = $response.errorHResult
                    Scope = $response.scope
                    ExternalId = $response.externalId
                    RequestSource = $response.requestSource
                    RelatedFileInfo = $response.relatedFileInfo
                    Commands = $response.commands
                    TroubleshootInfo = $response.troubleshootInfo
                }
            }
        } catch {
            Write-Error "Failed to PutFile on DeviceId: $DeviceId $_"
            $responses += [PSCustomObject]@{
                DeviceId = $DeviceId
                Error = $_.Exception.Message
            }
        }
    }
    return $responses
}

function Invoke-GetFile {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token,
        [Parameter(Mandatory = $true)]
        [string]$filePath,
        [Parameter(Mandatory = $true)]
        [string[]]$DeviceIds
    )
    $headers = @{
        "Authorization" = "Bearer $token"
    }
    $responses = @()
    foreach ($DeviceId in $DeviceIds) {
        Write-Host "Starting GetFile on DeviceId: $DeviceId"
        $body = @{
            "Commands" = @(
                @{
                    "type" = "GetFile"
                    "params" = @(
                        @{"key" = "Path"; "value" = "$filePath"}
                    )
                }
            )
            "Comment" = "MDEAutomator"
        } | ConvertTo-Json -Depth 10

        try {
            $response = Invoke-WithRetry -ScriptBlock {
                Invoke-RestMethod -Uri "https://api.securitycenter.microsoft.com/api/machines/$DeviceId/runliveresponse" -Method Post -Headers $headers -Body $body -ContentType "application/json" -ErrorAction Stop
            }

            $actionId = $response.id
            if ([string]::IsNullOrEmpty($actionId)) {
                Write-Host "No machine action ID received for DeviceId: $DeviceId. Marking as failed and continuing."
                $responses += [PSCustomObject]@{
                    DeviceId = $DeviceId
                    Status = "Failed"
                    Error = "No machine action ID received"
                }
                continue
            }
            Start-Sleep -Seconds 5
            $statusSucceeded = Get-MachineActionStatus -machineActionId $actionId -token $token

            if ($statusSucceeded) {
                Start-Sleep -Seconds 3
                $downloadUri = "https://api.securitycenter.microsoft.com/api/machineactions/$actionId/GetLiveResponseResultDownloadLink(index=0)"
                $downloadResponse = Invoke-RestMethod -Uri $downloadUri -Headers $headers -Method Get
                $FileUrl = $downloadResponse.value
                $responses += [PSCustomObject]@{
                    DeviceId = $DeviceId
                    Status = "Success"
                    FileUrl = $FileUrl
                    ActionId = $actionId
                }
            } else {
                Write-Error "Action failed or timed out for DeviceId: $DeviceId"
                $responses += [PSCustomObject]@{
                    DeviceId = $DeviceId
                    Status = "Failed"
                    Error = "Action failed or timed out"
                    ActionId = $actionId
                }
            }
        } catch {
            Write-Error "Exception occurred while processing DeviceId: $DeviceId. Error: $($_.Exception.Message)"
            $responses += [PSCustomObject]@{
                DeviceId = $DeviceId
                Status = "Failed"
                Error = $_.Exception.Message
            }
        }
    }
    return $responses
}
function Invoke-CollectInvestigationPackage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$DeviceIds
    )
    
    $headers = @{
        "Authorization" = "Bearer $token"
    }
    $responses = @()

    foreach ($DeviceId in $DeviceIds) {
        try {
            $body = @{
                "Comment" = "MDEAutomator"
            }

            $response = Invoke-WithRetry -ScriptBlock {
                param($uri, $headers, $body)
                Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -ContentType "application/json" -ErrorAction Stop
            } -ScriptBlockArgs @("https://api.securitycenter.microsoft.com/api/machines/$DeviceId/collectInvestigationPackage", $headers, ($body | ConvertTo-Json))

            $actionId = $response.id
            if ([string]::IsNullOrEmpty($actionId)) {
                Write-Host "No machine action ID received for DeviceId: $DeviceId. Marking as failed and continuing."
                $responses += [PSCustomObject]@{
                    DeviceId = $DeviceId
                    Status = "Failed"
                    Error = "No action ID received"
                }
                continue
            }
            Start-Sleep -Seconds 5
            $statusSucceeded = Get-MachineActionStatus -machineActionId $actionId -token $token

            if ($statusSucceeded) {
                Write-Host "Package collection succeeded for DeviceId: $DeviceId"
                Start-Sleep -Seconds 5
                
                $packageUriResponse = Invoke-WithRetry -ScriptBlock {
                    param($uri, $headers)
                    Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
                } -ScriptBlockArgs @("https://api.securitycenter.microsoft.com/api/machineactions/$actionId/getPackageUri", $headers)

                if ($packageUriResponse.value) {
                    $packageUri = $packageUriResponse.value
                    $responses += [PSCustomObject]@{
                        DeviceId = $DeviceId
                        Status = "Success"
                        PackageUri = $packageUri
                        ActionId = $actionId
                    }
                } else {
                    Write-Error "No package URI returned for DeviceId: $DeviceId"
                    $responses += [PSCustomObject]@{
                        DeviceId = $DeviceId
                        Status = "Failed"
                        Error = "No package URI returned"
                        ActionId = $actionId
                    }
                }
            } else {
                Write-Error "Package collection failed for DeviceId: $DeviceId"
                $responses += [PSCustomObject]@{
                    DeviceId = $DeviceId
                    Status = "Failed"
                    Error = "Package collection failed or timed out"
                    ActionId = $actionId
                }
            }
        } catch {
            Write-Error "Failed to process DeviceId: $DeviceId - $($_.Exception.Message)"
            $responses += [PSCustomObject]@{
                DeviceId = $DeviceId
                Status = "Failed"
                Error = $_.Exception.Message
            }
        }
    }
    return $responses
}

function Invoke-LRScript {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]] $DeviceIds,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $scriptName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $token
    )

    $responses = @()

    foreach ($DeviceId in $DeviceIds) {
        Write-Host "Starting LRScript execution on DeviceId: $DeviceId"

        try {
            $body = @{
                Commands = @(
                    @{
                        type = "RunScript"
                        params = @(
                            @{
                                key = "ScriptName"
                                value = $scriptName
                            }
                        )
                    }
                )
                Comment = "MDEAutomator"
            } | ConvertTo-Json -Depth 10

            $response = Invoke-WithRetry -ScriptBlock {
                param($DeviceId, $token, $body)
                try {
                    Invoke-RestMethod -Uri "https://api.securitycenter.microsoft.com/api/machines/$DeviceId/runliveresponse" `
                        -Method Post `
                        -Headers @{ Authorization = "Bearer $token" } `
                        -Body $body `
                        -ContentType "application/json" `
                        -ErrorAction Stop
                }
                catch {
                    if ($_.Exception.Response.StatusCode -eq 400) {
                        Write-Host "Failed: DeviceId-$DeviceId"
                        return $null
                    }
                    throw
                }
            } -ScriptBlockArgs @($DeviceId, $token, $body) -AllowNullResponse $true

            if ($response.status -eq "Pending") {
                Write-Host "Running Live Response script on DeviceId: $($response.id)"
                Start-Sleep -Seconds 5

                $machineActionId = $response.id
                $statusSucceeded = Get-MachineActionStatus -machineActionId $machineActionId -token $token
                $responses += [PSCustomObject]@{
                    DeviceId        = $DeviceId
                    MachineActionId = $machineActionId
                    Success         = [bool]$statusSucceeded
                }
                continue
            }

            $responses += [PSCustomObject]@{
                DeviceId        = $DeviceId
                MachineActionId = $null
                Success         = $false
            }
        }
        catch {
            Write-Error "Error processing DeviceId $DeviceId : $($_.Exception.Message)"
            $responses += [PSCustomObject]@{
                DeviceId        = $DeviceId
                MachineActionId = $null
                Success         = $false
            }
        }
    }
    Write-Host "Live Response script execution completed. Total responses: $($responses.Count)"
    return $responses
}

Function Get-MachineActionStatus {
    param (
        [Parameter(Mandatory=$true)]
        [string] $machineActionId,
        [Parameter(Mandatory=$true)]
        [string] $token
    )

    $uri = "https://api.securitycenter.microsoft.com/api/machineactions/$machineActionId"
    $headers = @{
        "Authorization" = "Bearer $token"
    }

    $timeout = New-TimeSpan -Minutes 11
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    while ($stopwatch.Elapsed -lt $timeout) {
        try {
            $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
            $status = $response.status

            switch ($status) {
                "Succeeded" {
                    Write-Host "MDE Machine action has succeeded."
                    return $true
                }
                "Failed" {
                    Write-Host "MDE Machine action has failed."
                    return $false
                }
                "Pending" {
                    Write-Host "MDE Machine action is pending."
                    Start-Sleep -Seconds 15
                }
                "InProgress" {
                    Write-Host "MDE Machine action is pending."
                    Start-Sleep -Seconds 15
                }
                default {
                    Write-Host "Unknown status: $status"
                    Write-Host "Full response received:"
                    Write-Host ($response | Out-String)
                    return $false
                }
            }
        } catch {
            Write-Host "An error occurred: $_"
            return $false
        }
    }
    Write-Host "MDE Machine action has timed out."
    return $false
}

Function Get-LiveResponseOutput {
    param (
        [Parameter(Mandatory=$true)]
        [string] $machineActionId,
        [Parameter(Mandatory=$true)]
        [string] $token
    )

    $uri = "https://api.securitycenter.microsoft.com/api/machineactions/$machineActionId/GetLiveResponseResultDownloadLink(index=0)"
    $headers = @{
        "Authorization" = "Bearer $token"
    }

    try {
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
        if ($response -and $response.'@odata.context') {
            $downloadLink = $response.value
            $tempFilePath = [System.IO.Path]::GetTempFileName()
            Invoke-WebRequest -Uri $downloadLink -OutFile $tempFilePath
            $content = Get-Content -Path $tempFilePath -Raw
            try {
                $jsonResponse = $content | ConvertFrom-Json
                $scriptName = $jsonResponse.script_name
                $exitCode = $jsonResponse.exit_code
                $scriptOutput = $jsonResponse.script_output
                $scriptErrors = $jsonResponse.script_errors
                Remove-Item -Path $tempFilePath
                return [PSCustomObject]@{
                    ScriptName      = $scriptName
                    ExitCode        = $exitCode
                    ScriptOutput    = $scriptOutput
                    ScriptErrors    = $scriptErrors
                    Status          = "Success"
                    MachineActionId = $machineActionId
                }
            } catch {
                Remove-Item -Path $tempFilePath
                return [PSCustomObject]@{
                    ScriptName      = $null
                    ExitCode        = $null
                    ScriptOutput    = $null
                    ScriptErrors    = $null
                    Status          = "Failed"
                    MachineActionId = $machineActionId
                    Error           = "Output is not valid JSON. Raw output: $content"
                }
            }
        } else {
            Write-Output "Failed to retrieve the download link."
            return [PSCustomObject]@{
                Status = "Failed"
                MachineActionId = $machineActionId
                Error = "Failed to retrieve the download link."
            }
        }
    } catch {
        Write-Output "An error occurred: $_"
        return [PSCustomObject]@{
            Status = "Failed"
            MachineActionId = $machineActionId
            Error = $_.Exception.Message
        }
    }
}

function Get-Machines {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token,
        [Parameter(Mandatory = $false)]
        [string]$filter
    )
    $baseFilter = "onboardingStatus eq 'Onboarded' and healthStatus eq 'Active'"
    if ($filter) {
        $combinedFilter = "$baseFilter and $filter"
    } else {
        $combinedFilter = $baseFilter
    }
    $uri = "https://api.securitycenter.microsoft.com/api/machines?`$filter=$combinedFilter" 
    $headers = @{
        "Authorization" = "Bearer $token"
    }
    $responses = @()
    try {
        do {
            $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
            $responses += $response.value | ForEach-Object {
                [PSCustomObject]@{
                    Id = $_.id
                    MergedIntoMachineId = $_.mergedIntoMachineId
                    IsPotentialDuplication = $_.isPotentialDuplication
                    IsExcluded = $_.isExcluded
                    ExclusionReason = $_.exclusionReason
                    ComputerDnsName = $_.computerDnsName
                    FirstSeen = $_.firstSeen
                    LastSeen = $_.lastSeen
                    OsPlatform = $_.osPlatform
                    OsVersion = $_.osVersion
                    OsProcessor = $_.osProcessor
                    Version = $_.version
                    LastIpAddress = $_.lastIpAddress
                    LastExternalIpAddress = $_.lastExternalIpAddress
                    AgentVersion = $_.agentVersion
                    OsBuild = $_.osBuild
                    HealthStatus = $_.healthStatus
                    DeviceValue = $_.deviceValue
                    RbacGroupId = $_.rbacGroupId
                    RbacGroupName = $_.rbacGroupName
                    RiskScore = $_.riskScore
                    ExposureLevel = $_.exposureLevel
                    IsAadJoined = $_.isAadJoined
                    AadDeviceId = $_.aadDeviceId
                    MachineTags = $_.machineTags
                    DefenderAvStatus = $_.defenderAvStatus
                    OnboardingStatus = $_.onboardingStatus
                    OsArchitecture = $_.osArchitecture
                    ManagedBy = $_.managedBy
                    ManagedByStatus = $_.managedByStatus
                    IpAddresses = $_.ipAddresses
                    VmMetadata = $_.vmMetadata
                }
            }
            $uri = $response.'@odata.nextLink'
        } while ($uri)
        return $responses
    } catch {
        Write-Error "Failed to retrieve machines: $_"
    }
}

function Get-LoggedInUsers {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$DeviceIds
    )
    $headers = @{
        "Authorization" = "Bearer $token"
    }
    $allResponses = @()
    foreach ($DeviceId in $DeviceIds) {
        Write-Host "Retrieving logon users for DeviceId: $DeviceId"
        $uri = "https://api.securitycenter.microsoft.com/api/machines/$DeviceId/logonusers"
        try {
            $responses = @()
            do {
                $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
                $responses += $response.value | ForEach-Object {
                    [PSCustomObject]@{
                        DeviceId = $DeviceId
                        AccountName = $_.accountName
                        AccountDomain = $_.accountDomain
                        LogonType = $_.logonType
                        LogonTime = $_.logonTime
                        IsDomainAccount = $_.isDomainAccount
                        Sid = $_.sid
                        AccountSid = $_.accountSid
                        LogonId = $_.logonId
                        LogonIdType = $_.logonIdType
                        LogonSessionId = $_.logonSessionId
                        LogonProcess = $_.logonProcess
                        AuthenticationPackage = $_.authenticationPackage
                        LogonServer = $_.logonServer
                        LastSeen = $_.lastSeen
                    }
                }
                $uri = $response.'@odata.nextLink'
            } while ($uri)
            $allResponses += $responses
        } catch {
            Write-Error "Failed to retrieve logon users for DeviceId: $DeviceId - $($_.Exception.Message)"
        }
    }
    return $allResponses
}

function Get-Actions {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token
    )
    $startDate = (Get-Date).AddDays(-90).ToString("yyyy-MM-ddTHH:mm:ssZ")
    $uri = "https://api.securitycenter.microsoft.com/api/machineactions?`$filter=CreationDateTimeUtc ge $startDate&`$orderby=CreationDateTimeUtc desc"
    $headers = @{
        "Authorization" = "Bearer $token"
    }
    $allResults = @()
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
        $allResults += $response.value | ForEach-Object {
            [PSCustomObject]@{
                Id = $_.id
                Type = $_.type
                Title = $_.title
                Requestor = $_.requestor
                RequestorComment = $_.requestorComment
                Status = $_.status
                MachineId = $_.machineId
                ComputerDnsName = $_.computerDnsName
                CreationDateTimeUtc = $_.creationDateTimeUtc
                LastUpdateDateTimeUtc = $_.lastUpdateDateTimeUtc
                CancellationRequestor = $_.cancellationRequestor
                CancellationComment = $_.cancellationComment
                CancellationDateTimeUtc = $_.cancellationDateTimeUtc
                ErrorHResult = $_.errorHResult
                Scope = $_.scope
                ExternalId = $_.externalId
                RequestSource = $_.requestSource
                RelatedFileInfo = $_.relatedFileInfo
                Commands = $_.commands
                TroubleshootInfo = $_.troubleshootInfo
            }
        }
        while ($response.'@odata.nextLink') {
            $response = Invoke-RestMethod -Uri $response.'@odata.nextLink' -Method Get -Headers $headers -ErrorAction Stop
            $allResults += $response.value | ForEach-Object {
                [PSCustomObject]@{
                    Id = $_.id
                    Type = $_.type
                    Title = $_.title
                    Requestor = $_.requestor
                    RequestorComment = $_.requestorComment
                    Status = $_.status
                    MachineId = $_.machineId
                    ComputerDnsName = $_.computerDnsName
                    CreationDateTimeUtc = $_.creationDateTimeUtc
                    LastUpdateDateTimeUtc = $_.lastUpdateDateTimeUtc
                    CancellationRequestor = $_.cancellationRequestor
                    CancellationComment = $_.cancellationComment
                    CancellationDateTimeUtc = $_.cancellationDateTimeUtc
                    ErrorHResult = $_.errorHResult
                    Scope = $_.scope
                    ExternalId = $_.externalId
                    RequestSource = $_.requestSource
                    RelatedFileInfo = $_.relatedFileInfo
                    Commands = $_.commands
                    TroubleshootInfo = $_.troubleshootInfo
                }
            }
        }
        return $allResults
    } catch {
        Write-Error "Failed to retrieve machine actions: $_"
    }
}
function Undo-Actions {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token
    )

    $allActions = Get-Actions -token $token
    $pendingActions = $allActions | Where-Object { $_.Status -eq "Pending" }

    Write-Host "Found $($pendingActions.Count) pending actions to cancel."

    $headers = @{
        "Authorization" = "Bearer $token"
    }
    $responses = @()

    foreach ($action in $pendingActions) {
        $actionId = $action.Id
        $uri = "https://api.securitycenter.microsoft.com/api/machineactions/$actionId/cancel"
        $body = @{
            "Comment" = "MDEAutomator"
        } | ConvertTo-Json

        try {
            $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body
            $responses += [PSCustomObject]@{
                ActionId = $actionId
                Status = "Canceled"
                Response = $response
            }
        } catch {
            if ($_.Exception.Response.StatusCode -eq 400) {
                Write-Host "Action $actionId could not be canceled. Skipping."
                $responses += [PSCustomObject]@{
                    ActionId = $actionId
                    Status = "Skipped"
                    Error = $_.Exception.Message
                }
                continue
            }
            Write-Error "Failed to cancel action $actionId $($_.Exception.Message)"
            $responses += [PSCustomObject]@{
                ActionId = $actionId
                Status = "Failed"
                Error = $_.Exception.Message
            }
        }
    }
    Write-Host "Undo-Actions completed. Total processed: $($responses.Count)"
    return $responses
}

function Get-FileInfo {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$Sha1s
    )
    $headers = @{
        "Authorization" = "Bearer $token"
    }
    $responses = @()

    foreach ($Sha1 in $Sha1s) {
        $uri1 = "https://api.security.microsoft.com/api/files/$Sha1"
        $uri2 = "https://api.securitycenter.microsoft.com/api/files/$Sha1/alerts"
        $uri3 = "https://api.securitycenter.microsoft.com/api/files/$Sha1/machines"
        $uri4 = "https://api.securitycenter.microsoft.com/api/files/$Sha1/stats"
        $uri5 = "https://api.securitycenter.microsoft.com/api/advancedqueries/run"

        try {
            $response1 = Invoke-RestMethod -Uri $uri1 -Method Get -Headers $headers -ErrorAction Stop
            $response2 = Invoke-RestMethod -Uri $uri2 -Method Get -Headers $headers -ErrorAction Stop
            $response3 = Invoke-RestMethod -Uri $uri3 -Method Get -Headers $headers -ErrorAction Stop
            $response4 = Invoke-RestMethod -Uri $uri4 -Method Get -Headers $headers -ErrorAction Stop
            $response = [PSCustomObject]@{
                FileInfo = $response1
                Alerts = $response2
                Machines = $response3
                Stats = $response4
            }

            $kqlQuery = "DeviceFileEvents | where SHA1 == '$Sha1' | summarize Count = count() by DeviceName, DeviceId | top 100 by Count"
            $body = @{
                "Query" = $kqlQuery
            }
            $advancedHuntingResponse = Invoke-RestMethod -Uri $uri5 -Method Post -Headers $headers -Body ($body | ConvertTo-Json) -ContentType "application/json" -ErrorAction Stop

            Write-Host "Successfully retrieved file information for Sha1: $Sha1"
            $responses += [PSCustomObject]@{
                Sha1 = $Sha1
                Response = $response
                AdvancedHuntingData = $advancedHuntingResponse.Results
            }
        } catch {
            Write-Error "Failed to retrieve file information for Sha1: $Sha1 $_"
            $responses += [PSCustomObject]@{
                Sha1 = $Sha1
                Error = $_.Exception.Message
            }
        }
    }
    return $responses
}
function Get-IPInfo {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$IPs
    )
    $headers = @{
        "Authorization" = "Bearer $token"
    }
    $responses = @()

    foreach ($IP in $IPs) {
        $uri1 = "https://api.securitycenter.microsoft.com/api/ips/$IP/alerts"
        $uri2 = "https://api.security.microsoft.com/api/ips/$IP/stats"
        $uri3 = "https://api.securitycenter.microsoft.com/api/advancedqueries/run"

        try {
            $response1 = Invoke-RestMethod -Uri $uri1 -Method Get -Headers $headers -ErrorAction Stop
            $response2 = Invoke-RestMethod -Uri $uri2 -Method Get -Headers $headers -ErrorAction Stop
            $response = [PSCustomObject]@{
                Alerts = $response1
                Stats = $response2
            }

            $kqlQuery = "DeviceNetworkEvents | where RemoteIP == '$IP' | summarize Count = count() by DeviceName, DeviceId | top 100 by Count"
            $body = @{
                "Query" = $kqlQuery
            }
            
            $advancedHuntingResponse = Invoke-RestMethod -Uri $uri3 -Method Post -Headers $headers -Body ($body | ConvertTo-Json) -ContentType "application/json" -ErrorAction Stop

            Write-Host "Successfully retrieved IP information for IP: $IP"
            $responses += [PSCustomObject]@{
                IP = $IP
                Response = $response
                AdvancedHuntingData = $advancedHuntingResponse.Results
            }
        } catch {
            Write-Error "Failed to retrieve IP information for IP: $IP $_"
            $responses += [PSCustomObject]@{
                IP = $IP
                Error = $_.Exception.Message
            }
        }
    }
    return $responses
}

function Get-URLInfo {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$URLs
    )
    $headers = @{
        "Authorization" = "Bearer $token"
    }
    $responses = @()

    foreach ($URL in $URLs) {
        $uri1 = "https://api.securitycenter.microsoft.com/api/domains/$URL/alerts"
        $uri2 = "https://api.security.microsoft.com/api/domains/$URL/stats"
        $uri3 = "https://api.security.microsoft.com/api/domains/$URL/machines"
        $uri4 = "https://api.securitycenter.microsoft.com/api/advancedqueries/run"

        try {
            $response1 = Invoke-RestMethod -Uri $uri1 -Method Get -Headers $headers -ErrorAction Stop
            $response2 = Invoke-RestMethod -Uri $uri2 -Method Get -Headers $headers -ErrorAction Stop
            $response3 = Invoke-RestMethod -Uri $uri3 -Method Get -Headers $headers -ErrorAction Stop
            $response = [PSCustomObject]@{
                Alerts = $response1
                Stats = $response2
                Machines = $response3
            }

            $kqlQuery = "DeviceNetworkEvents | where RemoteUri == '$URL' | summarize Count = count() by DeviceName, DeviceId | top 100 by Count"
            $body = @{
                "Query" = $kqlQuery
            }
            
            $advancedHuntingResponse = Invoke-RestMethod -Uri $uri4 -Method Post -Headers $headers -Body ($body | ConvertTo-Json) -ContentType "application/json" -ErrorAction Stop

            Write-Host "Successfully retrieved URL information for URL: $URL"
            $responses += [PSCustomObject]@{
                IP = $IP
                Response = $response
                AdvancedHuntingData = $advancedHuntingResponse.Results
            }
        } catch {
            Write-Error "Failed to retrieve URL information for URL: $URL $_"
            $responses += [PSCustomObject]@{
                IP = $IP
                Error = $_.Exception.Message
            }
        }
    }
    return $responses
}

function Invoke-MachineIsolation {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$DeviceIds
    )
    $headers = @{
        "Authorization" = "Bearer $token"
    }
    $body = @{
        "Comment" = "MDEAutomator"
        "IsolationType" = "Selective"
    }
    $responses = @()

    foreach ($DeviceId in $DeviceIds) {
        $uri = "https://api.securitycenter.microsoft.com/api/machines/$DeviceId/isolate"
        try {
            $response = Invoke-WithRetry -ScriptBlock {
                Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body ($body | ConvertTo-Json) -ContentType "application/json" -ErrorAction Stop
            }

            $actionId = $response.id
            if ([string]::IsNullOrEmpty($response.id)) {
                Write-Host "No machine action ID received for DeviceId: $DeviceId. Marking as failed and continuing."
                continue
            }
            Start-Sleep -Seconds 5
            $statusSucceeded = Get-MachineActionStatus -machineActionId $actionId -token $token

            if ($statusSucceeded) {
                Write-Host "Successfully isolated DeviceId: $DeviceId"
            } else {
                Write-Error "Failed to isolate DeviceId: $DeviceId"
            }

            $responses += [PSCustomObject]@{
                DeviceId = $DeviceId
                Response = [PSCustomObject]@{
                    Id = $response.id
                    Type = $response.type
                    Title = $response.title
                    Requestor = $response.requestor
                    RequestorComment = $response.requestorComment
                    Status = if ($statusSucceeded) { "Succeeded" } else { "Failed" }
                    MachineId = $response.machineId
                    ComputerDnsName = $response.computerDnsName
                    CreationDateTimeUtc = $response.creationDateTimeUtc
                    LastUpdateDateTimeUtc = $response.lastUpdateDateTimeUtc
                    CancellationRequestor = $response.cancellationRequestor
                    CancellationComment = $response.cancellationComment
                    CancellationDateTimeUtc = $response.cancellationDateTimeUtc
                    ErrorHResult = $response.errorHResult
                    Scope = $response.scope
                    ExternalId = $response.externalId
                    RequestSource = $response.requestSource
                    RelatedFileInfo = $response.relatedFileInfo
                    Commands = $response.commands
                    TroubleshootInfo = $response.troubleshootInfo
                }
            }
        } catch {
            Write-Error "Failed to initiate isolation for DeviceId: $DeviceId $_"
            $responses += [PSCustomObject]@{
                DeviceId = $DeviceId
                Error = $_.Exception.Message
            }
        }
    }
    return $responses
}

function Undo-MachineIsolation {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$DeviceIds
    )
    $headers = @{
        "Authorization" = "Bearer $token"
    }
    $body = @{
        "Comment" = "MDEAutomator"
    }
    $responses = @()

    foreach ($DeviceId in $DeviceIds) {
        $uri = "https://api.securitycenter.microsoft.com/api/machines/$DeviceId/unisolate"
        try {
            $response = Invoke-WithRetry -ScriptBlock {
                Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body ($body | ConvertTo-Json) -ContentType "application/json" -ErrorAction Stop
            }

            $actionId = $response.id
            if ([string]::IsNullOrEmpty($response.id)) {
                Write-Host "No machine action ID received for DeviceId: $DeviceId. Marking as failed and continuing."
                continue
            }
            Start-Sleep -Seconds 5
            $statusSucceeded = Get-MachineActionStatus -machineActionId $actionId -token $token

            if ($statusSucceeded) {
                Write-Host "Successfully unisolated DeviceId: $DeviceId"
            } else {
                Write-Error "Failed to unisolate DeviceId: $DeviceId"
            }

            $responses += [PSCustomObject]@{
                DeviceId = $DeviceId
                Response = [PSCustomObject]@{
                    Id = $response.id
                    Type = $response.type
                    Title = $response.title
                    Requestor = $response.requestor
                    RequestorComment = $response.requestorComment
                    Status = if ($statusSucceeded) { "Succeeded" } else { "Failed" }
                    MachineId = $response.machineId
                    ComputerDnsName = $response.computerDnsName
                    CreationDateTimeUtc = $response.creationDateTimeUtc
                    LastUpdateDateTimeUtc = $response.lastUpdateDateTimeUtc
                    CancellationRequestor = $response.cancellationRequestor
                    CancellationComment = $response.cancellationComment
                    CancellationDateTimeUtc = $response.cancellationDateTimeUtc
                    ErrorHResult = $response.errorHResult
                    Scope = $response.scope
                    ExternalId = $response.externalId
                    RequestSource = $response.requestSource
                    RelatedFileInfo = $response.relatedFileInfo
                    Commands = $response.commands
                    TroubleshootInfo = $response.troubleshootInfo
                }
            }
        } catch {
            Write-Error "Failed to unisolate DeviceId: $DeviceId $_"
            $responses += [PSCustomObject]@{
                DeviceId = $DeviceId
                Error = $_.Exception.Message
            }
        }
    }
    return $responses 
}

function Invoke-ContainDevice {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$DeviceIds
    )
    $headers = @{
        "Authorization" = "Bearer $token"
    }
    $body = @{
        "Comment" = "MDEAutomator"
        "IsolationType" = "UnManagedDevice"
    }
    $responses = @()

    foreach ($DeviceId in $DeviceIds) {
        $uri = "https://api.securitycenter.microsoft.com/api/machines/$DeviceId/isolate"
        try {
            $response = Invoke-WithRetry -ScriptBlock {
                Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body ($body | ConvertTo-Json) -ContentType "application/json" -ErrorAction Stop
            }

            $actionId = $response.id
            if ([string]::IsNullOrEmpty($response.id)) {
                Write-Host "No machine action ID received for DeviceId: $DeviceId. Marking as failed and continuing."
                continue
            }
            Start-Sleep -Seconds 5
            $statusSucceeded = Get-MachineActionStatus -machineActionId $actionId -token $token

            if ($statusSucceeded) {
                Write-Host "Successfully contained DeviceId: $DeviceId"
            } else {
                Write-Error "Failed to contain DeviceId: $DeviceId"
            }

            $responses += [PSCustomObject]@{
                DeviceId = $DeviceId
                Response = [PSCustomObject]@{
                    Id = $response.id
                    Type = $response.type
                    Title = $response.title
                    Requestor = $response.requestor
                    RequestorComment = $response.requestorComment
                    Status = if ($statusSucceeded) { "Succeeded" } else { "Failed" }
                    MachineId = $response.machineId
                    ComputerDnsName = $response.computerDnsName
                    CreationDateTimeUtc = $response.creationDateTimeUtc
                    LastUpdateDateTimeUtc = $response.lastUpdateDateTimeUtc
                    CancellationRequestor = $response.cancellationRequestor
                    CancellationComment = $response.cancellationComment
                    CancellationDateTimeUtc = $response.cancellationDateTimeUtc
                    ErrorHResult = $response.errorHResult
                    Scope = $response.scope
                    ExternalId = $response.externalId
                    RequestSource = $response.requestSource
                    RelatedFileInfo = $response.relatedFileInfo
                    Commands = $response.commands
                    TroubleshootInfo = $response.troubleshootInfo
                }
            }
        } catch {
            Write-Error "Failed to initiate containment for DeviceId: $DeviceId $_"
            $responses += [PSCustomObject]@{
                DeviceId = $DeviceId
                Error = $_.Exception.Message
            }
        }
    }
    return $responses
}

function Undo-ContainDevice {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$DeviceIds
    )
    $headers = @{
        "Authorization" = "Bearer $token"
    }
    $body = @{
        "Comment" = "MDEAutomator"
    }
    $responses = @()

    foreach ($DeviceId in $DeviceIds) {
        $uri = "https://api.securitycenter.microsoft.com/api/machines/$DeviceId/unisolate"
        try {
            $response = Invoke-WithRetry -ScriptBlock {
                Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body ($body | ConvertTo-Json) -ContentType "application/json" -ErrorAction Stop
            }

            $actionId = $response.id
            if ([string]::IsNullOrEmpty($response.id)) {
                Write-Host "No machine action ID received for DeviceId: $DeviceId. Marking as failed and continuing."
                continue
            }
            Start-Sleep -Seconds 5
            $statusSucceeded = Get-MachineActionStatus -machineActionId $actionId -token $token

            if ($statusSucceeded) {
                Write-Host "Successfully uncontained DeviceId: $DeviceId"
            } else {
                Write-Error "Failed to uncontain DeviceId: $DeviceId"
            }

            $responses += [PSCustomObject]@{
                DeviceId = $DeviceId
                Response = [PSCustomObject]@{
                    Id = $response.id
                    Type = $response.type
                    Title = $response.title
                    Requestor = $response.requestor
                    RequestorComment = $response.requestorComment
                    Status = if ($statusSucceeded) { "Succeeded" } else { "Failed" }
                    MachineId = $response.machineId
                    ComputerDnsName = $response.computerDnsName
                    CreationDateTimeUtc = $response.creationDateTimeUtc
                    LastUpdateDateTimeUtc = $response.lastUpdateDateTimeUtc
                    CancellationRequestor = $response.cancellationRequestor
                    CancellationComment = $response.cancellationComment
                    CancellationDateTimeUtc = $response.cancellationDateTimeUtc
                    ErrorHResult = $response.errorHResult
                    Scope = $response.scope
                    ExternalId = $response.externalId
                    RequestSource = $response.requestSource
                    RelatedFileInfo = $response.relatedFileInfo
                    Commands = $response.commands
                    TroubleshootInfo = $response.troubleshootInfo
                }
            }
        } catch {
            Write-Error "Failed to uncontain DeviceId: $DeviceId $_"
            $responses += [PSCustomObject]@{
                DeviceId = $DeviceId
                Error = $_.Exception.Message
            }
        }
    }
    return $responses 
}


function Invoke-RestrictAppExecution {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$DeviceIds
    )
    $headers = @{
        "Authorization" = "Bearer $token"
    }
    $body = @{
        "Comment" = "MDEAutomator"
    }
    $responses = @()

    foreach ($DeviceId in $DeviceIds) {
        $uri = "https://api.securitycenter.microsoft.com/api/machines/$DeviceId/restrictCodeExecution"
        try {
            $response = Invoke-WithRetry -ScriptBlock {
                Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body ($body | ConvertTo-Json) -ContentType "application/json" -ErrorAction Stop
            }

            $actionId = $response.id
            if ([string]::IsNullOrEmpty($response.id)) {
                Write-Host "No machine action ID received for DeviceId: $DeviceId. Marking as failed and continuing."
                continue
            }
            Start-Sleep -Seconds 5
            $statusSucceeded = Get-MachineActionStatus -machineActionId $actionId -token $token

            if ($statusSucceeded) {
                Write-Host "Successfully restricted code execution on DeviceId: $DeviceId"
            } else {
                Write-Error "Failed to restrict code execution on DeviceId: $DeviceId"
            }

            $responses += [PSCustomObject]@{
                DeviceId = $DeviceId
                Response = [PSCustomObject]@{
                    Id = $response.id
                    Type = $response.type
                    Title = $response.title
                    Requestor = $response.requestor
                    RequestorComment = $response.requestorComment
                    Status = if ($statusSucceeded) { "Succeeded" } else { "Failed" }
                    MachineId = $response.machineId
                    ComputerDnsName = $response.computerDnsName
                    CreationDateTimeUtc = $response.creationDateTimeUtc
                    LastUpdateDateTimeUtc = $response.lastUpdateDateTimeUtc
                    CancellationRequestor = $response.cancellationRequestor
                    CancellationComment = $response.cancellationComment
                    CancellationDateTimeUtc = $response.cancellationDateTimeUtc
                    ErrorHResult = $response.errorHResult
                    Scope = $response.scope
                    ExternalId = $response.externalId
                    RequestSource = $response.requestSource
                    RelatedFileInfo = $response.relatedFileInfo
                    Commands = $response.commands
                    TroubleshootInfo = $response.troubleshootInfo
                }
            }
        } catch {
            Write-Error "Failed to restrict code execution on DeviceId: $DeviceId $_"
            $responses += [PSCustomObject]@{
                DeviceId = $DeviceId
                Error = $_.Exception.Message
            }
        }
    }
    return $responses
}

function Undo-RestrictAppExecution {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$DeviceIds
    )
    $headers = @{
        "Authorization" = "Bearer $token"
    }
    $body = @{
        "Comment" = "MDEAutomator"
    }
    $responses = @()

    foreach ($DeviceId in $DeviceIds) {
        $uri = "https://api.securitycenter.microsoft.com/api/machines/$DeviceId/unrestrictCodeExecution"
        try {
            $response = Invoke-WithRetry -ScriptBlock {
                Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body ($body | ConvertTo-Json) -ContentType "application/json" -ErrorAction Stop
            }

            $actionId = $response.id
            if ([string]::IsNullOrEmpty($response.id)) {
                Write-Host "No machine action ID received for DeviceId: $DeviceId. Marking as failed and continuing."
                continue
            }
            Start-Sleep -Seconds 5
            $statusSucceeded = Get-MachineActionStatus -machineActionId $actionId -token $token

            if ($statusSucceeded) {
                Write-Host "Successfully unrestricted code execution on DeviceId: $DeviceId"
            } else {
                Write-Error "Failed to unrestrict code execution on DeviceId: $DeviceId"
            }

            $responses += [PSCustomObject]@{
                DeviceId = $DeviceId
                Response = [PSCustomObject]@{
                    Id = $response.id
                    Type = $response.type
                    Title = $response.title
                    Requestor = $response.requestor
                    RequestorComment = $response.requestorComment
                    Status = if ($statusSucceeded) { "Succeeded" } else { "Failed" }
                    MachineId = $response.machineId
                    ComputerDnsName = $response.computerDnsName
                    CreationDateTimeUtc = $response.creationDateTimeUtc
                    LastUpdateDateTimeUtc = $response.lastUpdateDateTimeUtc
                    CancellationRequestor = $response.cancellationRequestor
                    CancellationComment = $response.cancellationComment
                    CancellationDateTimeUtc = $response.cancellationDateTimeUtc
                    ErrorHResult = $response.errorHResult
                    Scope = $response.scope
                    ExternalId = $response.externalId
                    RequestSource = $response.requestSource
                    RelatedFileInfo = $response.relatedFileInfo
                    Commands = $response.commands
                    TroubleshootInfo = $response.troubleshootInfo
                }
            }
        } catch {
            Write-Error "Failed to unrestrict code execution on DeviceId: $DeviceId $_"
            $responses += [PSCustomObject]@{
                DeviceId = $DeviceId
                Error = $_.Exception.Message
            }
        }
    }
    return $responses
}

function Invoke-StopAndQuarantineFile {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token,
        [Parameter(Mandatory = $true)]
        [string]$Sha1
    )
    $headers = @{
        "Authorization" = "Bearer $token"
    }
    $responses = @()

    # Get all onboarded and active machines
    $machines = Get-Machines -token $token
    if (-not $machines -or $machines.Count -eq 0) {
        Write-Error "No machines found to process."
        return $responses
    }

    foreach ($machine in $machines) {
        $DeviceId = $machine.Id
        $uri = "https://api.securitycenter.microsoft.com/api/machines/$DeviceId/StopAndQuarantineFile"
        $body = @{
            "Comment" = "MDEAutomator"
            "Sha1"    = $Sha1
        } | ConvertTo-Json
        try {
            $response = Invoke-WithRetry -ScriptBlock {
                Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -ContentType "application/json" -ErrorAction Stop
            }
            Write-Host "Successfully invoked StopAndQuarantineFile on DeviceId: $DeviceId"
            $responses += [PSCustomObject]@{
                DeviceId = $DeviceId
                Response = $response
            }
        } catch {
            Write-Error "Failed to invoke StopAndQuarantineFile on DeviceId: $DeviceId $_"
            $responses += [PSCustomObject]@{
                DeviceId = $DeviceId
                Error = $_.Exception.Message
            }
        }
    }
    return $responses
}

function Get-Indicators {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token
    )
    $uri = "https://api.securitycenter.microsoft.com/api/indicators"
    $headers = @{
        "Authorization" = "Bearer $token"
    }
    $allResults = @()
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
        $allResults += $response.value | ForEach-Object {
            [PSCustomObject]@{
                Id = $_.id
                IndicatorValue = $_.indicatorValue
                IndicatorType = $_.indicatorType
                Action = $_.action
                Application = $_.application
                Source = $_.source
                SourceType = $_.sourceType
                Title = $_.title
                CreationTimeDateTimeUtc = $_.creationTimeDateTimeUtc
                CreatedBy = $_.createdBy
                ExpirationTime = $_.expirationTime
                LastUpdateTime = $_.lastUpdateTime
                LastUpdatedBy = $_.lastUpdatedBy
                Severity = $_.severity
                Description = $_.description
                RecommendedActions = $_.recommendedActions
                RbacGroupNames = $_.rbacGroupNames
            }
        }
        while ($response.'@odata.nextLink') {
            $response = Invoke-RestMethod -Uri $response.'@odata.nextLink' -Method Get -Headers $headers -ErrorAction Stop
            $allResults += $response.value | ForEach-Object {
                [PSCustomObject]@{
                    Id = $_.id
                    IndicatorValue = $_.indicatorValue
                    IndicatorType = $_.indicatorType
                    Action = $_.action
                    Application = $_.application
                    Source = $_.source
                    SourceType = $_.sourceType
                    Title = $_.title
                    CreationTimeDateTimeUtc = $_.creationTimeDateTimeUtc
                    CreatedBy = $_.createdBy
                    ExpirationTime = $_.expirationTime
                    LastUpdateTime = $_.lastUpdateTime
                    LastUpdatedBy = $_.lastUpdatedBy
                    Severity = $_.severity
                    Description = $_.description
                    RecommendedActions = $_.recommendedActions
                    RbacGroupNames = $_.rbacGroupNames
                }
            }
        }
        return $allResults
    } catch {
        Write-Error "Failed to retrieve indicators: $_"
    }
}
function Invoke-TiFile {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token,
        [Parameter(Mandatory = $false)]
        [string[]]$Sha1s,
        [Parameter(Mandatory = $false)]
        [string[]]$Sha256s
    )
    $uri = "https://api.securitycenter.microsoft.com/api/indicators"
    $headers = @{
        "Authorization" = "Bearer $token"
    }
    $responses = @()

    if ($Sha1s) {
        foreach ($Sha1 in $Sha1s) {
            $body = @{
                "indicatorValue" = $Sha1
                "indicatorType" = "FileSha1"
                "title" = "MDEAutomator $Sha1"
                "action" = "BlockAndRemediate"
                "severity" = "High"
                "description" = "MDEautomator has created this Custom Threat Indicator."
                "recommendedActions" = "Investigate & take appropriate action."
            }
            try {
                $response = Invoke-WithRetry -ScriptBlock {
                    Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body ($body | ConvertTo-Json) -ContentType "application/json" -ErrorAction Stop
                }
                Write-Output "Successfully created Threat Indicator for Sha1: $Sha1"
                $responses += [PSCustomObject]@{
                    Sha1 = $Sha1
                    Response = $response
                }
            } catch {
                Write-Error "Failed to create Threat Indicator for Sha1: $Sha1 $_"
                $responses += [PSCustomObject]@{
                    Sha1 = $Sha1
                    Error = $_.Exception.Message
                }
            }
        }
    }

    if ($Sha256s) {
        foreach ($Sha256 in $Sha256s) {
            $body = @{
                "indicatorValue" = $Sha256
                "indicatorType" = "FileSha256"
                "title" = "MDEAutomator $Sha256"
                "action" = "BlockAndRemediate"
                "severity" = "High"
                "description" = "MDEautomator has created this Custom Threat Indicator."
                "recommendedActions" = "Investigate & take appropriate action."
            }
            try {
                $response = Invoke-WithRetry -ScriptBlock {
                    Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body ($body | ConvertTo-Json) -ContentType "application/json" -ErrorAction Stop
                }
                Write-Output "Successfully created Threat Indicator for Sha256: $Sha256"
                $responses += [PSCustomObject]@{
                    Sha256 = $Sha256
                    Response = $response
                }
            } catch {
                Write-Error "Failed to create Threat Indicator for Sha256: $Sha256 $_"
                $responses += [PSCustomObject]@{
                    Sha256 = $Sha256
                    Error = $_.Exception.Message
                }
            }
        }
    }
    return $responses
}

function Undo-TiFile {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token,
        [Parameter(Mandatory = $false)]
        [string[]]$Sha1s,
        [Parameter(Mandatory = $false)]
        [string[]]$Sha256s
    )
    $headers = @{
        "Authorization" = "Bearer $token"
    }
    $responses = @()

    if ($Sha1s) {
        foreach ($Sha1 in $Sha1s) {
            $uriGet = "https://api.securitycenter.microsoft.com/api/indicators?`$filter=indicatorValue eq '$Sha1'"
            try {
                $responseGet = Invoke-RestMethod -Uri $uriGet -Method Get -Headers $headers -ErrorAction Stop
                if ($responseGet.value.Count -eq 0) {
                    Write-Error "No Threat Indicator found for Sha1: $Sha1"
                    $responses += [PSCustomObject]@{
                        Sha1 = $Sha1
                        Error = "No Threat Indicator found"
                    }
                    continue
                }

                $indicatorId = $responseGet.value[0].id
                $uriDelete = "https://api.securitycenter.microsoft.com/api/indicators/$indicatorId"

                $responseDelete = Invoke-WithRetry -ScriptBlock {
                    Invoke-RestMethod -Uri $uriDelete -Method Delete -Headers $headers -ErrorAction Stop
                }
                Write-Output "Successfully deleted Threat Indicator for Sha1: $Sha1"
                $responses += [PSCustomObject]@{
                    Sha1 = $Sha1
                    Response = $responseDelete
                }
            } catch {
                Write-Error "Failed to delete Threat Indicator for Sha1: $Sha1 $_"
                $responses += [PSCustomObject]@{
                    Sha1 = $Sha1
                    Error = $_.Exception.Message
                }
            }
        }
    }

    if ($Sha256s) {
        foreach ($Sha256 in $Sha256s) {
            $uriGet = "https://api.securitycenter.microsoft.com/api/indicators?`$filter=indicatorValue eq '$Sha256'"
            try {
                $responseGet = Invoke-RestMethod -Uri $uriGet -Method Get -Headers $headers -ErrorAction Stop
                if ($responseGet.value.Count -eq 0) {
                    Write-Error "No Threat Indicator found for Sha256: $Sha256"
                    $responses += [PSCustomObject]@{
                        Sha256 = $Sha256
                        Error = "No Threat Indicator found"
                    }
                    continue
                }

                $indicatorId = $responseGet.value[0].id
                $uriDelete = "https://api.securitycenter.microsoft.com/api/indicators/$indicatorId"

                $responseDelete = Invoke-WithRetry -ScriptBlock {
                    Invoke-RestMethod -Uri $uriDelete -Method Delete -Headers $headers -ErrorAction Stop
                }
                Write-Output "Successfully deleted Threat Indicator for Sha256: $Sha256"
                $responses += [PSCustomObject]@{
                    Sha256 = $Sha256
                    Response = $responseDelete
                }
            } catch {
                Write-Error "Failed to delete Threat Indicator for Sha256: $Sha256 $_"
                $responses += [PSCustomObject]@{
                    Sha256 = $Sha256
                    Error = $_.Exception.Message
                }
            }
        }
    }

    return $responses 
}

function Invoke-TiIP {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$IPs
    )
    $uri = "https://api.securitycenter.microsoft.com/api/indicators"
    $headers = @{
        "Authorization" = "Bearer $token"
    }
    $responses = @()
    $rfc1918

    foreach ($IP in $IPs) {
        
            if ($ip -match '^10\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$' -or
                $ip -match '^172\.(1[6-9]|2[0-9]|3[0-1])\.(\d{1,3})\.(\d{1,3})$' -or
                $ip -match '^192\.168\.(\d{1,3})\.(\d{1,3})$') {
                Write-Host "$ip is RFC1918 (private). Cannot add Private IP address as an MDE Indicator" -ForegroundColor Red
                $rfc1918 = $true
            } else {
                Write-Output "$ip is public. Proceeding to add Indicator to MDE"
                $rfc1918 = $false
            }
        
        
        if(-not ($rfc1918)){
            $body = @{
                "indicatorValue" = $IP
                "indicatorType" = "IpAddress"
                "action" = "Block"
                "severity" = "High"
                "title" = "MDEAutomator $IP"
                "description" = "MDEautomator has created this Custom Threat Indicator."
                "recommendedActions" = "Investigate & take appropriate action."
            }
            try {
                $response = Invoke-WithRetry -ScriptBlock {
                    try {
                        Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body ($body | ConvertTo-Json) -ContentType "application/json" -ErrorAction Stop
                    } catch {
                        if ($_.Exception.Response.StatusCode -eq 404) {
                            Write-Host "API responded with 'not found'. Continuing execution."
                        } else {
                            throw $_
                        }
                    }
                }
                Write-Host "Successfully created Threat Indicator for IP: $IP"
                $responses += [PSCustomObject]@{
                    IP = $IP
                    Response = $response
                }
            } catch {
                Write-Error "Failed to create Threat Indicator for IP: $IP $_"
                $responses += [PSCustomObject]@{
                    IP = $IP
                    Error = $_.Exception.Message
                }
            }
        }
    }
    return $responses
}

function Undo-TiURL {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$URLs
    )
    $headers = @{
        "Authorization" = "Bearer $token"
    }
    $responses = @()

    foreach ($URL in $URLs) {
        $uriGet = "https://api.securitycenter.microsoft.com/api/indicators?`$filter=indicatorValue eq '$URL'"
        try {
            $responseGet = Invoke-RestMethod -Uri $uriGet -Method Get -Headers $headers -ErrorAction Stop
            if ($responseGet.value.Count -eq 0) {
                Write-Error "No Threat Indicator found for URL: $URL"
                $responses += [PSCustomObject]@{
                    URL = $URL
                    Error = "No Threat Indicator found"
                }
                continue
            }

            $indicatorId = $responseGet.value[0].id
            $uriDelete = "https://api.securitycenter.microsoft.com/api/indicators/$indicatorId"

            $responseDelete = Invoke-WithRetry -ScriptBlock {
                Invoke-RestMethod -Uri $uriDelete -Method Delete -Headers $headers -ErrorAction Stop
            }
            Write-Output "Successfully deleted Threat Indicator for URL: $URL"
            $responses += [PSCustomObject]@{
                URL = $URL
                Response = $responseDelete
            }
        } catch {
            Write-Error "Failed to delete Threat Indicator for URL: $URL $_"
            $responses += [PSCustomObject]@{
                URL = $URL
                Error = $_.Exception.Message
            }
        }
    }
    return $responses
}

function Invoke-TiURL {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$URLs
    )
    $uri = "https://api.securitycenter.microsoft.com/api/indicators"
    $headers = @{
        "Authorization" = "Bearer $token"
    }
    $responses = @()

    foreach ($URL in $URLs) {
        $body = @{
            "indicatorValue" = "$URL"
            "indicatorType" = "DomainName"
            "action" = "Block"
            "severity" = "High"
            "title" = "MDEAutomator $URL"
            "description" = "MDEautomator has created this Custom Threat Indicator."
            "recommendedActions" = "Investigate & take appropriate action."
        }
        try {
            $response = Invoke-WithRetry -ScriptBlock {
                Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body ($body | ConvertTo-Json) -ContentType "application/json" -ErrorAction Stop
            }
            Write-Host "Successfully created Threat Indicator for URL: $URL"
            $responses += [PSCustomObject]@{
                URL = $URL
                Response = $response
            }
        } catch {
            Write-Error "Failed to create Threat Indicator for URL: $URL $_"
            $responses += [PSCustomObject]@{
                URL = $URL
                Error = $_.Exception.Message
            }
        }
    }
    return $responses
}

function Undo-TiIP {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$IPs
    )
    $headers = @{
        "Authorization" = "Bearer $token"
    }
    $responses = @()

    foreach ($IP in $IPs) {
        $uriGet = "https://api.securitycenter.microsoft.com/api/indicators?`$filter=indicatorValue eq '$IP'"
        try {
            $responseGet = Invoke-RestMethod -Uri $uriGet -Method Get -Headers $headers -ErrorAction Stop
            if ($responseGet.value.Count -eq 0) {
                Write-Error "No Threat Indicator found for IP: $IP"
                $responses += [PSCustomObject]@{
                    IP = $IP
                    Error = "No Threat Indicator found"
                }
                continue
            }

            $indicatorId = $responseGet.value[0].id
            $uriDelete = "https://api.securitycenter.microsoft.com/api/indicators/$indicatorId"

            $responseDelete = Invoke-WithRetry -ScriptBlock {
                Invoke-RestMethod -Uri $uriDelete -Method Delete -Headers $headers -ErrorAction Stop
            }
            Write-Output "Successfully deleted Threat Indicator for IP: $IP"
            $responses += [PSCustomObject]@{
                IP = $IP
                Response = $responseDelete
            }
        } catch {
            Write-Error "Failed to delete Threat Indicator for IP: $IP $_"
            $responses += [PSCustomObject]@{
                IP = $IP
                Error = $_.Exception.Message
            }
        }
    }
    return $responses
}
function Invoke-TiCert {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token,
        [Parameter(Mandatory = $false)]
        [string[]]$Sha1s
    )
    $uri = "https://api.securitycenter.microsoft.com/api/indicators"
    $headers = @{
        "Authorization" = "Bearer $token"
    }
    $responses = @()

    if ($Sha1s) {
        foreach ($Sha1 in $Sha1s) {
            $body = @{
                "indicatorValue" = $Sha1
                "indicatorType" = "CertificateThumbprint"
                "title" = "MDEAutomator $Sha1"
                "action" = "Block"
                "severity" = "High"
                "description" = "MDEautomator has created this Custom Threat Indicator."
                "recommendedActions" = "Investigate & take appropriate action."
            }
            try {
                $response = Invoke-WithRetry -ScriptBlock {
                    Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body ($body | ConvertTo-Json) -ContentType "application/json" -ErrorAction Stop
                }
                Write-Output "Successfully created Threat Indicator for Sha1: $Sha1"
                $responses += [PSCustomObject]@{
                    Sha1 = $Sha1
                    Response = $response
                }
            } catch {
                Write-Error "Failed to create Threat Indicator for Sha1: $Sha1 $_"
                $responses += [PSCustomObject]@{
                    Sha1 = $Sha1
                    Error = $_.Exception.Message
                }
            }
        }
    }

    return $responses
}

function Undo-TiCert {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token,
        [Parameter(Mandatory = $false)]
        [string[]]$Sha1s
    )
    $headers = @{
        "Authorization" = "Bearer $token"
    }
    $responses = @()

    if ($Sha1s) {
        foreach ($Sha1 in $Sha1s) {
            $uriGet = "https://api.securitycenter.microsoft.com/api/indicators?`$filter=indicatorValue eq '$Sha1'"
            try {
                $responseGet = Invoke-RestMethod -Uri $uriGet -Method Get -Headers $headers -ErrorAction Stop
                if ($responseGet.value.Count -eq 0) {
                    Write-Error "No Threat Indicator found for Sha1: $Sha1"
                    $responses += [PSCustomObject]@{
                        Sha1 = $Sha1
                        Error = "No Threat Indicator found"
                    }
                    continue
                }

                $indicatorId = $responseGet.value[0].id
                $uriDelete = "https://api.securitycenter.microsoft.com/api/indicators/$indicatorId"

                $responseDelete = Invoke-WithRetry -ScriptBlock {
                    Invoke-RestMethod -Uri $uriDelete -Method Delete -Headers $headers -ErrorAction Stop
                }
                Write-Output "Successfully deleted Threat Indicator for Sha1: $Sha1"
                $responses += [PSCustomObject]@{
                    Sha1 = $Sha1
                    Response = $responseDelete
                }
            } catch {
                Write-Error "Failed to delete Threat Indicator for Sha1: $Sha1 $_"
                $responses += [PSCustomObject]@{
                    Sha1 = $Sha1
                    Error = $_.Exception.Message
                }
            }
        }
    }

    return $responses
}

Function Invoke-AdvancedHunting {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$Queries
    )

    $endpoints = @(
        "https://graph.microsoft.com/v1.0/security/runHuntingQuery",
        "https://graph.microsoft.com/beta/security/runHuntingQuery"
    )

    $responses = @()

    foreach ($query in $Queries) {
        $uri = $endpoints | Get-Random

        $body = @{
            "Query" = $query
        } | ConvertTo-Json

        try {
            $response = Invoke-WithRetry -ScriptBlock {
                Invoke-MgGraphRequest -Uri $uri -Method POST -Body $body -ContentType "application/json"
            }
            $responses += [PSCustomObject]@{
                Query = $query
                Response = $response
            }
            Write-Host "Query completed successfully"
        } catch {
            Write-Error "Query failed $($_.Exception.Message)"
            $responses += [PSCustomObject]@{
                Query = $query
                Endpoint = $uri
                Error = $_.Exception.Message
            }
        }
    }
    return $responses
}

# Export the functions
Export-ModuleMember -Function Connect-MDE, Connect-MDEGraph, Get-AccessToken, Get-Machines, Get-Actions, Undo-Actions, Invoke-MachineIsolation, Undo-MachineIsolation, Invoke-ContainDevice, Undo-ContainDevice,
    Invoke-RestrictAppExecution, Undo-RestrictAppExecution, Invoke-TiFile, Undo-TiFile, Invoke-TiCert, Undo-TiCert, Invoke-TiIP, Undo-TiIP, 
    Invoke-TiURL, Undo-TiURL, Get-RequestParam, Get-SecretFromKeyVault, Get-IPInfo, Get-FileInfo, Get-URLInfo, Get-LoggedInUsers, Get-Indicators,
    Invoke-WithRetry, Invoke-UploadLR, Invoke-PutFile, Invoke-GetFile, Invoke-CollectInvestigationPackage, Invoke-LRScript, 
    Get-MachineActionStatus, Get-LiveResponseOutput, Invoke-FullDiskScan, Invoke-StopAndQuarantineFile, Invoke-AdvancedHunting