<#
.SYNOPSIS
    MDEAutomator PowerShell Module - Automates Microsoft Defender for Endpoint (MDE) API operations.

.DESCRIPTION
    This module provides a set of functions to automate common Microsoft Defender for Endpoint (MDE) tasks via the MDE API, including device management, live response actions, threat indicator management, and more. It supports robust error handling, retry logic, and integration with Azure Key Vault for secure secret management.

.FUNCTIONS
    Connect-MDE
        Authenticates to MDE using a Federated App Registration + UMI (FIC/Workload Identity). Also supports $SPNSECRET for local/dev environments.

    Get-Machines
        Retrieves a list of onboarded and active devices from MDE, with optional filtering.

    Get-Actions
        Retrieves recent machine actions performed in MDE.

    Undo-Actions
        Cancels all pending machine actions in MDE.

    Get-IPInfo
        Retrieves information, alerts, and statistics for specified IP addresses.

    Get-FileInfo
        Retrieves file metadata, alerts, machine associations, and stats for specified file hashes.

    Get-URLInfo
        Retrieves information, alerts, machine associations, and stats for specified URLs/domains.

    Get-LoggedInUsers
        Retrieves logon user information for specified devices.

    Get-MachineActionStatus
        Polls and returns the status of a machine action by ID.

    Invoke-AdvancedHunting
        Executes advanced hunting queries using Microsoft Graph Security API.

    Invoke-UploadLR
        Uploads a script file to the MDE Live Response library.

    Invoke-PutFile
        Pushes a file from the Live Response library to specified devices.

    Invoke-GetFile
        Retrieves a file from specified devices using Live Response.

    Invoke-LRScript
        Executes a Live Response script on specified devices.

    Get-LiveResponseOutput
        Downloads and parses the output of a Live Response script execution.

    Invoke-MachineIsolation / Undo-MachineIsolation
        Isolates or unisolates specified devices in MDE.

    Invoke-ContainDevice / Undo-ContainDevice
        Contains or uncontains specified unmanaged devices in MDE.

    Invoke-RestrictAppExecution / Undo-RestrictAppExecution
        Restricts or unrestricts application execution on specified devices.
        
    Invoke-FullDiskScan
        Initiates a full antivirus scan on specified devices.

    Invoke-StopAndQuarantineFile
        Stops and quarantines a file on all onboarded devices.

    Invoke-CollectInvestigationPackage
        Collects an investigation package from specified devices.

    Get-Indicators
        Retrieves all custom threat indicators from MDE.

    Invoke-TiFile / Undo-TiFile
        Creates or deletes file hash-based custom threat indicators.

    Invoke-TiCert / Undo-TiCert
        Creates or deletes certificate thumbprint-based custom threat indicators.

    Invoke-TiIP / Undo-TiIP
        Creates or deletes IP address-based custom threat indicators.

    Invoke-TiURL / Undo-TiURL
        Creates or deletes URL/domain-based custom threat indicators.

    Get-DetectionRules
        Retrieves all Microsoft Defender detection rules via Microsoft Graph API.

    Install-DetectionRule
        Installs a new detection rule in Microsoft Defender via Microsoft Graph API.

    Update-DetectionRule
        Updates an existing detection rule in Microsoft Defender via Microsoft Graph API.

.PARAMETERS
    All functions require an OAuth2 access token (`$token`) obtained via Connect-MDE.
    Device-specific functions require one or more device IDs (`$DeviceIds`).
    Threat indicator functions require indicator values (e.g., `$Sha1s`, `$Sha256s`, `$IPs`, `$URLs`).

.NOTES
    - Requires PowerShell 5.1+ and the Az.Accounts.
    - Error handling and retry logic are built-in for robust automation.
    - For more information, see the official Microsoft Defender for Endpoint API documentation.

.AUTHOR
    github.com/msdirtbag

.VERSION
    1.5.3

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

function Connect-MDE {
    [OutputType([System.Security.SecureString])]
    param (
        [Parameter(Mandatory = $true)]
        [string] $SpnId,
        [Parameter(Mandatory = $false)]
        [securestring] $SpnSecret,
        [Parameter(Mandatory = $false)]
        [string] $TenantId,
        [Parameter(Mandatory = $false)]
        [string] $ManagedIdentityId
    )

    Write-Host "Connecting to MDE (this may take a few minutes)"

    if ([string]::IsNullOrEmpty($SpnId)) {
        Write-Error "SpnId parameter is required"
        exit 1
    }

    if ([string]::IsNullOrEmpty($TenantId)) {
        try {
            $TenantId = (Get-AzContext).Tenant.Id
            if ([string]::IsNullOrEmpty($TenantId)) {
                Write-Error "Unable to determine TenantId from context. Please provide TenantId parameter."
                exit 1
            }
            Write-Host "Using TenantId from current Azure context: $TenantId"
        }
        catch {
            Write-Error "Failed to get Azure context. Please provide TenantId parameter. Error: $_"
            exit 1
        }
    }

    # Ensure required modules are available
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        Write-Host "Microsoft.Graph module not found. Installing for first use..."
        Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber | Out-Null
    }
    if (-not (Get-Module -Name Microsoft.Graph.Authentication)) {
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop | Out-Null
    }
    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        Write-Host "Az.Accounts module not found. Installing for first use..."
        Install-Module -Name Az.Accounts -Scope CurrentUser -Force -AllowClobber | Out-Null
    }
    if (-not (Get-Module -Name Az.Accounts)) {
        Import-Module Az.Accounts -ErrorAction Stop | Out-Null
    }

    $finalToken = $null

    # 1. Manual SPN secret flow (local/dev)
    if ($null -ne $SpnSecret) {
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SpnSecret)
        $plainSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        try {
            $resourceAppIdUri = 'https://api.securitycenter.microsoft.com'
            $oAuthUri = "https://login.microsoftonline.com/$TenantId/oauth2/token"
            $body = [Ordered]@{
                resource      = $resourceAppIdUri
                client_id     = $SpnId
                client_secret = $plainSecret
                grant_type    = 'client_credentials'
            }
            $response = Invoke-RestMethod -Method Post -Uri $oAuthUri -Body $body -ErrorAction Stop
            $tokenString = $response.access_token
            $finalToken = ConvertTo-SecureString -String $tokenString -AsPlainText -Force
            Write-Host "Successfully obtained token using client secret"
        } catch {
            Write-Error "Failed to retrieve access token for MDE using client secret. Error: $_"
            exit 1
        }
    }

    # 2. Federated App Registration + UMI (FIC/Workload Identity)
    elseif (-not [string]::IsNullOrEmpty($ManagedIdentityId)) {
        Write-Host "Using Managed Identity authentication with ID: $ManagedIdentityId"
        try {
            Update-AzConfig -DisplayBreakingChangeWarning $false | Out-Null
            Connect-AzAccount -Identity -AccountId $ManagedIdentityId | Out-Null
            $Audience = "api://AzureADTokenExchange"
            $aztoken = Get-AzAccessToken -ResourceUrl $Audience
            Connect-AzAccount -ApplicationId $SpnId -FederatedToken $aztoken.Token -Tenant $TenantId | Out-Null
            $tokenObj = Get-AzAccessToken -ResourceUrl "https://api.securitycenter.microsoft.com/" -TenantId $TenantId          
            $tokenString = $tokenObj.Token
            $graphTokenObj = Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com/" -TenantId $TenantId
            $graphTokenString = $graphTokenObj.Token
            $graphTokenSecure = ConvertTo-SecureString -String $graphTokenString -AsPlainText -Force
            Connect-MgGraph -AccessToken $graphTokenSecure -NoWelcome | Out-Null
            $finalToken = ConvertTo-SecureString -String $tokenString -AsPlainText -Force
            
            Write-Host "Federated App Registration + UMI authentication to MDE & Graph API complete."
        } catch {
            Write-Error "Failed federated UMI authentication. Error: $_"
            exit 1
        }
    }
    else {
        Write-Error "Either SpnSecret or ManagedIdentityId must be provided"
        exit 1
    }
    return $finalToken
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
        [securestring]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$DeviceIds
    )
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $headers = @{
        "Authorization" = "Bearer $plainToken"
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
    [CmdletBinding(DefaultParameterSetName = "ByPath")]
    param (
        [Parameter(Mandatory = $true)]
        [securestring]$token,

        [Parameter(Mandatory = $true, ParameterSetName = "ByPath", Position = 0)]
        [string]$filePath,

        [Parameter(Mandatory = $true, ParameterSetName = "ByContent", Position = 0)]
        [byte[]]$fileContent,

        [Parameter(Mandatory = $false, ParameterSetName = "ByPath", Position = 1)]
        [Parameter(Mandatory = $true, ParameterSetName = "ByContent", Position = 1)]
        [string]$TargetFileName
    )

    $memoryStream = $null
    try {
        $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
        )
        $headers = @{
            "Authorization" = "Bearer $plainToken"
        }

        [string]$resolvedFileName
        [byte[]]$resolvedFileBytes

        if ($PSCmdlet.ParameterSetName -eq "ByPath") {
            $resolvedFileName = if (-not [string]::IsNullOrEmpty($TargetFileName)) { $TargetFileName } else { [System.IO.Path]::GetFileName($filePath) }
            if (-not (Test-Path -Path $filePath -PathType Leaf)) {
                throw "File not found at path: $filePath"
            }
            $resolvedFileBytes = [System.IO.File]::ReadAllBytes($filePath)
        }
        elseif ($PSCmdlet.ParameterSetName -eq "ByContent") {
            $resolvedFileName = $TargetFileName 
            $resolvedFileBytes = $fileContent 
        }

        $boundary = [System.Guid]::NewGuid().ToString() 
        $LF = "`r`n" # Carriage return and line feed

        $memoryStream = New-Object System.IO.MemoryStream
        
        # File part
        $fileHeaderString = "--$boundary$LF" +
                            "Content-Disposition: form-data; name=`"file`"; filename=`"$resolvedFileName`"$LF" +
                            "Content-Type: application/octet-stream$LF$LF"
        $fileHeaderBytes = [System.Text.Encoding]::UTF8.GetBytes($fileHeaderString)
        $memoryStream.Write($fileHeaderBytes, 0, $fileHeaderBytes.Length)
        $memoryStream.Write($resolvedFileBytes, 0, $resolvedFileBytes.Length)
        $memoryStream.Write([System.Text.Encoding]::UTF8.GetBytes($LF), 0, [System.Text.Encoding]::UTF8.GetBytes($LF).Length)

        # ParametersDescription part
        $parametersDescriptionString = "--$boundary$LF" +
                                       "Content-Disposition: form-data; name=`"ParametersDescription`"$LF$LF" +
                                       "test$LF" # Hardcoded value
        $parametersDescriptionBytes = [System.Text.Encoding]::UTF8.GetBytes($parametersDescriptionString)
        $memoryStream.Write($parametersDescriptionBytes, 0, $parametersDescriptionBytes.Length)

        # HasParameters part
        $hasParametersString = "--$boundary$LF" +
                               "Content-Disposition: form-data; name=`"HasParameters`"$LF$LF" +
                               "false$LF" # Hardcoded value
        $hasParametersBytes = [System.Text.Encoding]::UTF8.GetBytes($hasParametersString)
        $memoryStream.Write($hasParametersBytes, 0, $hasParametersBytes.Length)

        # OverrideIfExists part
        $overrideIfExistsString = "--$boundary$LF" +
                                  "Content-Disposition: form-data; name=`"OverrideIfExists`"$LF$LF" +
                                  "true$LF" # Hardcoded value
        $overrideIfExistsBytes = [System.Text.Encoding]::UTF8.GetBytes($overrideIfExistsString)
        $memoryStream.Write($overrideIfExistsBytes, 0, $overrideIfExistsBytes.Length)

        # Description part
        $descriptionString = "--$boundary$LF" +
                             "Content-Disposition: form-data; name=`"Description`"$LF$LF" +
                             "test description$LF" # Hardcoded value
        $descriptionBytes = [System.Text.Encoding]::UTF8.GetBytes($descriptionString)
        $memoryStream.Write($descriptionBytes, 0, $descriptionBytes.Length)
        
        # Final boundary
        $finalBoundaryBytes = [System.Text.Encoding]::UTF8.GetBytes("--$boundary--$LF")
        $memoryStream.Write($finalBoundaryBytes, 0, $finalBoundaryBytes.Length)
        
        $memoryStream.Seek(0, [System.IO.SeekOrigin]::Begin) | Out-Null
        $bodyBytes = $memoryStream.ToArray()
        
        Invoke-RestMethod -Uri "https://api.security.microsoft.com/api/libraryfiles" -Method Post -Headers $headers -ContentType "multipart/form-data; boundary=$boundary" -Body $bodyBytes -ErrorAction Stop | Out-Null
        Write-Host "Successfully uploaded file: $resolvedFileName"
    } catch {
        if ($_.Exception.Message -notlike "*already exists*") {
            Write-Host "Error uploading script to library: $($_.Exception.Message)"
            exit 
        }
    }
    finally {
        if ($null -ne $memoryStream) {
            $memoryStream.Dispose()
        }
    }
}


function Invoke-PutFile {
    param (
        [Parameter(Mandatory = $true)]
        [securestring]$token,
        [Parameter(Mandatory = $true)]
        [string]$fileName,
        [Parameter(Mandatory = $true)]
        [string[]]$DeviceIds
    )
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $headers = @{
        "Authorization" = "Bearer $plainToken"
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
        [securestring]$token,
        [Parameter(Mandatory = $true)]
        [string]$filePath,
        [Parameter(Mandatory = $true)]
        [string[]]$DeviceIds
    )
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $headers = @{
        "Authorization" = "Bearer $plainToken"
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
        [securestring]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$DeviceIds
    )
    
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $headers = @{
        "Authorization" = "Bearer $plainToken"
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
        [string[]] $DeviceIds,

        [Parameter(Mandatory = $true)]
        [string] $scriptName,

        [Parameter(Mandatory = $true)]
        [securestring] $token
    )

    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $headers = @{
        "Authorization" = "Bearer $plainToken"
    }

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
                param($DeviceId, $headers, $body)
                try {
                    Invoke-RestMethod -Uri "https://api.securitycenter.microsoft.com/api/machines/$DeviceId/runliveresponse" `
                        -Method Post `
                        -Headers $headers `
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
            } -ScriptBlockArgs @($DeviceId, $headers, $body) -AllowNullResponse $true

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
                Error           = $_.Exception.Message
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
        [securestring] $token
    )

    $uri = "https://api.securitycenter.microsoft.com/api/machineactions/$machineActionId"
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $headers = @{
        "Authorization" = "Bearer $plainToken"
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
        [securestring] $token
    )

    $uri = "https://api.securitycenter.microsoft.com/api/machineactions/$machineActionId/GetLiveResponseResultDownloadLink(index=0)"
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $headers = @{
        "Authorization" = "Bearer $plainToken"
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
        [securestring]$token,
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
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $headers = @{
        "Authorization" = "Bearer $plainToken"
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
        [securestring]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$DeviceIds
    )
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $headers = @{
        "Authorization" = "Bearer $plainToken"
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
        [securestring]$token
    )
    $startDate = (Get-Date).AddDays(-90).ToString("yyyy-MM-ddTHH:mm:ssZ")
    $uri = "https://api.securitycenter.microsoft.com/api/machineactions?`$filter=CreationDateTimeUtc ge $startDate&`$orderby=CreationDateTimeUtc desc"
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $headers = @{
        "Authorization" = "Bearer $plainToken"
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
        [securestring]$token
    )

    $allActions = Get-Actions -token $token
    $pendingActions = $allActions | Where-Object { $_.Status -eq "Pending" }

    Write-Host "Found $($pendingActions.Count) pending actions to cancel."

    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $headers = @{
        "Authorization" = "Bearer $plainToken"
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
        [securestring]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$Sha1s
    )
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $headers = @{
        "Authorization" = "Bearer $plainToken"
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
        [securestring]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$IPs
    )
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $headers = @{
        "Authorization" = "Bearer $plainToken"
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
        [securestring]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$URLs
    )
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $headers = @{
        "Authorization" = "Bearer $plainToken"
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
        [securestring]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$DeviceIds
    )
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $headers = @{
        "Authorization" = "Bearer $plainToken"
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
        [securestring]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$DeviceIds
    )
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $headers = @{
        "Authorization" = "Bearer $plainToken"
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
        [securestring]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$DeviceIds
    )
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $headers = @{
        "Authorization" = "Bearer $plainToken"
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
        [securestring]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$DeviceIds
    )
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $headers = @{
        "Authorization" = "Bearer $plainToken"
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
        }
    }
    return $responses 
}

function Invoke-RestrictAppExecution {
    param (
        [Parameter(Mandatory = $true)]
        [securestring]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$DeviceIds
    )
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $headers = @{
        "Authorization" = "Bearer $plainToken"
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
        [securestring]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$DeviceIds
    )
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $headers = @{
        "Authorization" = "Bearer $plainToken"
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
        [securestring]$token,
        [Parameter(Mandatory = $true)]
        [string]$Sha1
    )
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $headers = @{
        "Authorization" = "Bearer $plainToken"
    }
    $responses = @()

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
        [securestring]$token
    )
    $uri = "https://api.securitycenter.microsoft.com/api/indicators"
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $headers = @{
        "Authorization" = "Bearer $plainToken"
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
        [securestring]$token,
        [Parameter(Mandatory = $false)]
        [string[]]$Sha1s,
        [Parameter(Mandatory = $false)]
        [string[]]$Sha256s
    )
    $uri = "https://api.securitycenter.microsoft.com/api/indicators"
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $headers = @{
        "Authorization" = "Bearer $plainToken"
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
        [securestring]$token,
        [Parameter(Mandatory = $false)]
        [string[]]$Sha1s,
        [Parameter(Mandatory = $false)]
        [string[]]$Sha256s
    )
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $headers = @{
        "Authorization" = "Bearer $plainToken"
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
        [securestring]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$IPs
    )
    $uri = "https://api.securitycenter.microsoft.com/api/indicators"
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $headers = @{
        "Authorization" = "Bearer $plainToken"
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
        [securestring]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$URLs
    )
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $headers = @{
        "Authorization" = "Bearer $plainToken"
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
        [securestring]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$URLs
    )
    $uri = "https://api.securitycenter.microsoft.com/api/indicators"
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $headers = @{
        "Authorization" = "Bearer $plainToken"
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
        [securestring]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$IPs
    )
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $headers = @{
        "Authorization" = "Bearer $plainToken"
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
        [securestring]$token,
        [Parameter(Mandatory = $false)]
        [string[]]$Sha1s
    )
    $uri = "https://api.securitycenter.microsoft.com/api/indicators"
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $headers = @{
        "Authorization" = "Bearer $plainToken"
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
        [securestring]$token,
        [Parameter(Mandatory = $false)]
        [string[]]$Sha1s
    )
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($token)
    )
    $headers = @{
        "Authorization" = "Bearer $plainToken"
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

function Get-DetectionRules {
    try {
        $uri = "https://graph.microsoft.com/beta/security/rules/detectionRules?$select=displayName"
        $allRules = @()
        do {
            $listResponse = Invoke-MgGraphRequest -Method GET -Uri $uri
            $listResponseJson = $listResponse | ConvertTo-Json -Depth 10 | ConvertFrom-Json
            $allRules += $listResponseJson.value
            $uri = $listResponseJson.'@odata.nextLink'
        } while ($uri)
        return $allRules
    } catch {
        Write-Error "Failed to retrieve detection rules: $_"
        exit 1
    }
}

function Install-DetectionRule {
    param (
        [PSCustomObject]$jsonContent
    )
    try {
        $bodyParameter = @{
            displayName = $jsonContent.DisplayName
            isEnabled = $jsonContent.IsEnabled
            queryCondition = @{
                queryText = $jsonContent.QueryCondition.QueryText
            }
            schedule = @{
                period = $jsonContent.Schedule.Period
            }
            detectionAction = @{
                alertTemplate = @{
                    title = $jsonContent.DetectionAction.AlertTemplate.Title
                    description = $jsonContent.DetectionAction.AlertTemplate.Description
                    severity = $jsonContent.DetectionAction.AlertTemplate.Severity
                    category = $jsonContent.DetectionAction.AlertTemplate.Category
                    mitreTechniques = $jsonContent.DetectionAction.AlertTemplate.MitreTechniques
                    recommendedActions = $jsonContent.DetectionAction.AlertTemplate.RecommendedActions
                    impactedAssets = @(
                        @{
                            "@odata.type" = "#microsoft.graph.security.impactedDeviceAsset"
                            "identifier" = "deviceId"
                        }
                    )
                }
            }
        }
        $bodyJson = $bodyParameter | ConvertTo-Json -Depth 10
        if (-not $bodyJson) {
            return
        }
        $response = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/security/rules/detectionRules" -Body $bodyJson
        if ($response -and $response.id) {
            Write-Host "Installed new detection rule: $($jsonContent.DisplayName)"
        } else {
            Write-Host "Failed to install detection rule: $($jsonContent.DisplayName). No ID returned in response."
        }
    } catch {
        Write-Host "Failed to install detection rule: $($jsonContent.DisplayName). Error: $_"
    }
}

function Update-DetectionRule {
    param (
        [string]$RuleId,
        [PSCustomObject]$jsonContent
    )
    try {
        $bodyParameter = @{
            displayName = $jsonContent.DisplayName
            isEnabled = $jsonContent.IsEnabled
            queryCondition = @{
                queryText = $jsonContent.QueryCondition.QueryText
            }
            schedule = @{
                period = $jsonContent.Schedule.Period
            }
            detectionAction = @{
                alertTemplate = @{
                    title = $jsonContent.DetectionAction.AlertTemplate.Title
                    description = $jsonContent.DetectionAction.AlertTemplate.Description
                    severity = $jsonContent.DetectionAction.AlertTemplate.Severity
                    category = $jsonContent.DetectionAction.AlertTemplate.Category
                    mitreTechniques = $jsonContent.DetectionAction.AlertTemplate.MitreTechniques
                    recommendedActions = $jsonContent.DetectionAction.AlertTemplate.RecommendedActions
                    impactedAssets = @(
                        @{
                            "@odata.type" = "#microsoft.graph.security.impactedDeviceAsset"
                            "identifier" = "deviceId"
                        }
                    )
                }
            }
        }
        $bodyJson = $bodyParameter | ConvertTo-Json -Depth 10
        if (-not $bodyJson) {
            return
        }
        $response = Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/beta/security/rules/detectionRules/$RuleId" -Body $bodyJson
        if ($response -and $response.id) {
            Write-Host "Updated detection rule: $($jsonContent.DisplayName)"
        } else {
            Write-Host "Failed to update detection rule: $($jsonContent.DisplayName). No ID returned in response."
        }
    } catch {
        Write-Host "Failed to update detection rule: $($jsonContent.DisplayName). Error: $_"
    }
}

function Undo-DetectionRule {
    param (
        [string]$RuleId
    )
    try {
        $uri = "https://graph.microsoft.com/beta/security/rules/detectionRules/$RuleId"
        $response = Invoke-MgGraphRequest -Method DELETE -Uri $uri
        if ($null -eq $response) {
            Write-Host "Deleted detection rule: $RuleId"
        } else {
            Write-Host "Failed to delete detection rule: $RuleId. Unexpected response."
        }
    } catch {
        Write-Host "Failed to delete detection rule: $RuleId. Error: $_"
    }
}

Export-ModuleMember -Function Connect-MDE, Get-RequestParam, Invoke-WithRetry,
    Get-Machines, Get-Actions, Undo-Actions, Get-IPInfo, Get-FileInfo, Get-URLInfo, Get-LoggedInUsers, Get-MachineActionStatus, Invoke-AdvancedHunting,
    Invoke-UploadLR, Invoke-PutFile, Invoke-GetFile, Invoke-LRScript, Get-LiveResponseOutput,
    Invoke-MachineIsolation, Undo-MachineIsolation, Invoke-ContainDevice, Undo-ContainDevice, Get-DetectionRules, Install-DetectionRule, Update-DetectionRule, Undo-DetectionRule,
    Invoke-RestrictAppExecution, Undo-RestrictAppExecution, Invoke-FullDiskScan, Invoke-StopAndQuarantineFile, Invoke-CollectInvestigationPackage,
    Get-Indicators, Invoke-TiFile, Undo-TiFile, Invoke-TiCert, Undo-TiCert, Invoke-TiIP, Undo-TiIP, Invoke-TiURL, Undo-TiURL