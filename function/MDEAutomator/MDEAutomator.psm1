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
    if (-not $TenantId) {
        $TenantId = (Get-AzContext).Tenant.Id
    }
    if (-not (Get-Module -ListAvailable -Name Az.KeyVault)) {
        Write-Host "Az PowerShell module not found. Installing for first use..."
        Install-Module -Name Az -Scope CurrentUser -Force -AllowClobber
    }
    if (-not (Get-Module -Name Az.KeyVault)) {
        Import-Module Az -ErrorAction Stop
    }

    if (-not (Get-AzContext)) {
        Write-Host "No Azure session detected. Please sign in."
        Connect-AzAccount -TenantId $TenantId -ErrorAction Stop
    }

    if (-not $SpnSecret) {
        $SpnSecret = (Get-AzKeyVaultSecret -VaultName $keyVaultName -Name 'SPNSECRET').SecretValue
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
                    Write-Warning "MDE says endpoint is unavailable. Marking as skipped."
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
    return $responses | ConvertTo-Json -Depth 10
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
    foreach ($DeviceId in $DeviceIds) {
        Write-Host "[DEBUG] Starting GetFile on DeviceId: $DeviceId"
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

        Write-Host "[DEBUG] Request URI: https://api.securitycenter.microsoft.com/api/machines/$DeviceId/runliveresponse"
        Write-Host "[DEBUG] Request Headers: $($headers | ConvertTo-Json -Depth 5)"
        Write-Host "[DEBUG] Request Body: $body"

        try {
            $response = Invoke-WithRetry -ScriptBlock {
                Invoke-RestMethod -Uri "https://api.securitycenter.microsoft.com/api/machines/$DeviceId/runliveresponse" -Method Post -Headers $headers -Body $body -ContentType "application/json" -ErrorAction Stop
            }

            Write-Host "[DEBUG] Response: $($response | ConvertTo-Json -Depth 10)"

            $actionId = $response.id
            if ([string]::IsNullOrEmpty($actionId)) {
                Write-Host "[DEBUG] No machine action ID received for DeviceId: $DeviceId. Marking as failed and continuing."
                continue
            }
            Start-Sleep -Seconds 5
            $statusSucceeded = Get-MachineActionStatus -machineActionId $actionId -token $token

            if ($statusSucceeded) {
                $downloadUri = "https://api.securitycenter.microsoft.com/api/machineactions/$actionId/GetLiveResponseResultDownloadLink(index=0)"
                Write-Host "[DEBUG] Download URI: $downloadUri"
                return $downloadUri
            } else {
                Write-Error "[DEBUG] Action failed or timed out for DeviceId: $DeviceId"
                return $null
            }
        } catch {
            Write-Error "[DEBUG] Exception occurred while processing DeviceId: $DeviceId. Error: $($_.Exception.Message)"
            return $null
        }
    }
}

function Invoke-CollectInvestigationPackage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token,
        [Parameter(Mandatory = $true)]
        [string[]]$DeviceIds,
        [Parameter(Mandatory = $true)]
        [string]$StorageAccountName
    )
    
    Write-Host "Starting investigation package collection for ${DeviceIds.Count} devices"
    $headers = @{
        "Authorization" = "Bearer $token"
    }
    $responses = @()

    foreach ($DeviceId in $DeviceIds) {
        try {
            Write-Host "Processing DeviceId: $DeviceId"
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
                continue
            }
            Start-Sleep -Seconds 5
            $statusSucceeded = Get-MachineActionStatus -machineActionId $actionId -token $token

            if ($statusSucceeded) {
                Write-Host "Package collection succeeded for DeviceId: $DeviceId"
                
                $packageUriResponse = Invoke-WithRetry -ScriptBlock {
                    param($uri, $headers)
                    Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
                } -ScriptBlockArgs @("https://api.securitycenter.microsoft.com/api/machineactions/$machineActionId/getPackageUri", $headers)

                if ($packageUriResponse.value) {
                    $packageUri = $packageUriResponse.value
                    Write-Host "Package download URL obtained"

                    try {
                        $packageContent = Invoke-WebRequest -Uri $packageUri -Headers $headers -Method Get -UseBasicParsing
                        Write-Host "Package downloaded successfully"
                        
                        $timestamp = Get-Date -Format "yyyyMMddHHmmss"
                        $blobName = "$DeviceId-$timestamp.zip"
                        $localPath = "$env:TEMP\$blobName"
                        
                        [System.IO.File]::WriteAllBytes($localPath, $packageContent.Content)
                        
                        $ctx = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount
                        $containerName = "packages"
                        Set-AzStorageBlobContent -File $localPath -Container $containerName -Blob $blobName -Context $ctx -Force
                        
                        Write-Host "Package uploaded to blob storage: $blobName"
                        Remove-Item $localPath
                        
                        $responses += [PSCustomObject]@{
                            DeviceId = $DeviceId
                            Status = "Success"
                            ActionId = $machineActionId
                            BlobName = $blobName
                            ContainerName = $containerName
                        }
                    }
                    catch {
                        Write-Error "Failed to process package: $($_.Exception.Message)"
                        $responses += [PSCustomObject]@{
                            DeviceId = $DeviceId
                            Status = "Failed"
                            Error = "Package processing failed: $($_.Exception.Message)"
                            ActionId = $machineActionId
                        }
                    }
                }
            } else {
                Write-Error "Package collection failed for DeviceId: $DeviceId"
                $responses += [PSCustomObject]@{
                    DeviceId = $DeviceId
                    Status = "Failed"
                    Error = "Package collection failed or timed out"
                    ActionId = $machineActionId
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
    Write-Host "Collection completed. Total responses: $($responses.Count)"
    return $responses | ConvertTo-Json -Depth 10
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

    $results = @()

    foreach ($DeviceId in $DeviceIds) {
        Write-Host "Starting execution for DeviceId: $DeviceId"

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
                Write-Host "Automating device: $($response.id)"
                Start-Sleep -Seconds 5

                $machineActionId = $response.id
                $statusSucceeded = Get-MachineActionStatus -machineActionId $machineActionId -token $token
                if (-not $statusSucceeded) {
                    $results += @{
                        Success = $false
                        DeviceId = $DeviceId
                        MachineActionId = $machineActionId
                    }
                    continue
                }
                $results += @{
                    Success = $true
                    DeviceId = $DeviceId
                    MachineActionId = $machineActionId
                }
                continue
            }

            $results += @{
                Success = $false
                DeviceId = $DeviceId
                Message = "Unexpected response status: $($response.status)"
            }
        }
        catch {
            Write-Error "Error processing DeviceId $DeviceId : $($_.Exception.Message)"
            $results += @{
                Success = $false
                DeviceId = $DeviceId
                Exception = @{
                    Type = $_.Exception.GetType().FullName
                    Message = $_.Exception.Message
                }
            }
        }
    }

    return $results | ConvertTo-Json -Depth 10
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

    $timeout = New-TimeSpan -Minutes 10
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
            $jsonResponse = $content | ConvertFrom-Json
            $scriptName = $jsonResponse.script_name
            $exitCode = $jsonResponse.exit_code
            $scriptOutput = $jsonResponse.script_output
            $scriptErrors = $jsonResponse.script_errors
            Remove-Item -Path $tempFilePath
            return @{
                ScriptName = $scriptName
                ExitCode = $exitCode
                ScriptOutput = $scriptOutput
                ScriptErrors = $scriptErrors
            }
        } else {
            Write-Output "Failed to retrieve the download link."
            return $false
        }
    } catch {
        Write-Output "An error occurred: $_"
        return $false
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
    $allResults = @()
    try {
        do {
            $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
            $allResults += $response.value | ForEach-Object {
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
        return $allResults | ConvertTo-Json -Depth 10
    } catch {
        Write-Error "Failed to retrieve machines: $_"
    }
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
        return $allResults | ConvertTo-Json -Depth 10
    } catch {
        Write-Error "Failed to retrieve machine actions: $_"
    }
}
function Undo-Actions {
    param (
        [Parameter(Mandatory = $true)]
        [string]$token
    )

    $allActionsJson = Get-Actions -token $token
    $allActions = $allActionsJson | ConvertFrom-Json
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

        Write-Host "Canceling action $actionId"

        try {
            $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -ErrorAction Stop
            Write-Host "Cancel response: $($response | ConvertTo-Json -Depth 10)"
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
    return $responses | ConvertTo-Json -Depth 10
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
    return $responses | ConvertTo-Json -Depth 10
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
    return $responses | ConvertTo-Json -Depth 10
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
    return $responses | ConvertTo-Json -Depth 10
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
            $statusSucceeded = Get-MachineActionStatus -machineActionId $actionId -token $tokenn

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
    return $responses | ConvertTo-Json -Depth 10
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

    return $responses | ConvertTo-Json -Depth 10
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

    return $responses | ConvertTo-Json -Depth 10
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

    foreach ($IP in $IPs) {
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
    return $responses | ConvertTo-Json -Depth 10
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
    return $responses | ConvertTo-Json -Depth 10
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
    return $responses | ConvertTo-Json -Depth 10
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
    return $responses | ConvertTo-Json -Depth 10
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

    return $responses | ConvertTo-Json -Depth 10
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

    return $responses | ConvertTo-Json -Depth 10
}

function Invoke-MachineOffboard {
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
        $uri = "https://api.securitycenter.microsoft.com/api/machines/$DeviceId/offboard"
        try {
            Write-Host "Attempting to offboard DeviceId: $DeviceId"

            $response = $null
            try {
                $response = Invoke-WithRetry -ScriptBlock {
                    Invoke-RestMethod -Uri $using:uri -Method Post -Headers $using:headers -Body ($using:body | ConvertTo-Json) -ContentType "application/json" -ErrorAction Stop
                }
            }
            catch {
                if ($_.Exception.Response.StatusCode -eq 400 -and 
                    $_.Exception.Response.Content -match '"code":\s*"ActiveRequestAlreadyExists"') {
                    Write-Host "Action already in progress for DeviceId: $DeviceId"
                    $responses += [PSCustomObject]@{
                        DeviceId = $DeviceId
                        Response = [PSCustomObject]@{
                            Status = "InProgress"
                            Message = "Action already in progress"
                        }
                    }
                    continue
                }
                throw 
            }
            
            if ([string]::IsNullOrEmpty($response.id)) {
                Write-Host "No machine action ID received for DeviceId: $DeviceId"
                $responses += [PSCustomObject]@{
                    DeviceId = $DeviceId
                    Response = [PSCustomObject]@{
                        Status = "Failed"
                        Message = "No action ID received"
                    }
                }
                continue
            }

            $actionId = $response.id
            if ([string]::IsNullOrEmpty($response.id)) {
                Write-Host "No machine action ID received for DeviceId: $DeviceId. Marking as failed and continuing."
                continue
            }
            Start-Sleep -Seconds 5
            $statusSucceeded = Get-MachineActionStatus -machineActionId $actionId -token $token

            $responses += [PSCustomObject]@{
                DeviceId = $DeviceId
                Response = [PSCustomObject]@{
                    Id = $response.id
                    Type = $response.type
                    Title = $response.title
                    Status = if ($statusSucceeded) { "Succeeded" } else { "Failed" }
                    MachineId = $response.machineId
                    ComputerDnsName = $response.computerDnsName
                    CreationDateTimeUtc = $response.creationDateTimeUtc
                }
            }

            Write-Host "Offboarding status for DeviceId $DeviceId : $(if ($statusSucceeded) { 'Succeeded' } else { 'Failed' })"

        } catch {
            Write-Error "Failed to offboard DeviceId: $DeviceId. Error: $_"
            $responses += [PSCustomObject]@{
                DeviceId = $DeviceId
                Response = [PSCustomObject]@{
                    Status = "Error"
                    Message = $_.Exception.Message
                }
            }
        }
    }

    return $responses | ConvertTo-Json -Depth 10
}

# Export the functions
Export-ModuleMember -Function Connect-MDE, Get-AccessToken, Get-Machines, Get-Actions, Undo-Actions, Invoke-MachineIsolation, Undo-MachineIsolation, 
    Invoke-RestrictAppExecution, Undo-RestrictAppExecution, Invoke-TiFile, Undo-TiFile, Invoke-TiCert, Undo-TiCert, Invoke-TiIP, Undo-TiIP, 
    Invoke-TiURL, Undo-TiURL, Invoke-MachineOffboard, Get-RequestParam, Get-SecretFromKeyVault, 
    Invoke-WithRetry, Invoke-UploadLR, Invoke-PutFile, Invoke-GetFile, Invoke-CollectInvestigationPackage, Invoke-LRScript, 
    Get-MachineActionStatus, Get-LiveResponseOutput, Invoke-FullDiskScan