# MDEOrchestrator Function App
# 1.5.6

using namespace System.Net

param($Request)

try {
    # Extract parameters from the incoming HTTP request
    $TenantId   = Get-RequestParam -Name "TenantId"   -Request $Request
    $Function   = Get-RequestParam -Name "Function"   -Request $Request
    $DeviceIds  = Get-RequestParam -Name "DeviceIds"  -Request $Request
    $allDevices = Get-RequestParam -Name "allDevices" -Request $Request
    $Filter     = Get-RequestParam -Name "Filter"     -Request $Request
    $scriptName = Get-RequestParam -Name "scriptName" -Request $Request
    $filePath   = Get-RequestParam -Name "filePath"   -Request $Request
    $fileName   = Get-RequestParam -Name "fileName"   -Request $Request
    $fileContent   = Get-RequestParam -Name "fileContent"   -Request $Request
    $TargetFileName = Get-RequestParam -Name "TargetFileName"   -Request $Request

    # Retrieve environment variables for authentication
    $spnId             = [System.Environment]::GetEnvironmentVariable('SPNID', 'Process')
    $ManagedIdentityId = [System.Environment]::GetEnvironmentVariable('AZURE_CLIENT_ID', 'Process')
    $token             = Connect-MDE -TenantId $TenantId -SpnId $spnId -ManagedIdentityId $ManagedIdentityId

    # Reconnect to Azure after MDE connection
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity -AccountId $ManagedIdentityId | Out-Null
    $subscriptionId = [System.Environment]::GetEnvironmentVariable('SUBSCRIPTION_ID', 'Process')
    Set-AzContext -Subscription $subscriptionId -ErrorAction Stop

    # Early upload if fileContent and TargetFileName are present
    if ($fileContent -and $TargetFileName) {
        $bytesToUpload = if ($fileContent -is [byte[]]) { $fileContent } else { [System.Text.Encoding]::UTF8.GetBytes($fileContent) }
        $results = Invoke-UploadLR -token $token -fileContent $bytesToUpload -TargetFileName $TargetFileName
        $output = [PSCustomObject]@{
            Status = "Upload attempt finished. Check logs for details."
        }
        Write-Host "Invoke-UploadLR completed."
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body = $output | ConvertTo-Json -Depth 10
        })
        return
    }

    # Device discovery: get all or filtered devices if requested
    if ($allDevices -eq $true) {
        Write-Host "Getting all devices"
        $machines = Get-Machines -token $token
        if ($null -ne $machines) {
            $DeviceIds = @($machines | ForEach-Object { $_.Id })
        } else {
            $DeviceIds = @()
        }
        Write-Host "Machines returned: $($machines.Count)"
        Write-Host "DeviceIds: $($DeviceIds -join ' ')"
    }
    elseif ($null -ne $Filter -and $Filter -ne "") {
        Write-Host "Getting devices with filter: $Filter"
        $machines = Get-Machines -token $token -Filter $Filter
        if ($null -ne $machines) {
            $DeviceIds = @($machines | ForEach-Object { $_.Id })
        } else {
            $DeviceIds = @()
        }
        Write-Host "Machines returned: $($machines.Count)"
        Write-Host "DeviceIds: $($DeviceIds -join ' ')"
    }

    # Normalize DeviceIds to always be an array of strings
    if ($null -eq $DeviceIds) {
        $DeviceIds = @()
    } elseif ($DeviceIds -is [string]) {
        $DeviceIds = $DeviceIds -split '[\s,;]+' | Where-Object { $_ -ne "" }
    } elseif ($DeviceIds -is [System.Collections.IEnumerable]) {
        $DeviceIds = @($DeviceIds | ForEach-Object { "$_" } | Where-Object { $_ -ne "" })
    } else {
        $DeviceIds = @("$DeviceIds")
    }

    # If no devices to process and no file content is provided, return early
    if ($DeviceIds.Count -eq 0 -and (-not $fileContent)) {
        Write-Host "No DeviceIds to process and no fileContent provided. Exiting."
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body = "No DeviceIds to process."
        })
        return
    }

    $throttleLimit = 10 # Limit parallelism for Azure Function best practices

    # Main orchestration: process each device in parallel
    $orchestratorResults = $DeviceIds | ForEach-Object -Parallel {
        param($_)
        $DeviceId = $_
        Import-Module "$using:PSScriptRoot\..\MDEAutomator\MDEAutomator.psm1" -Force
        try {
            switch ($using:Function) {
                "InvokeLRScript" {
                    if (-not $using:scriptName) { throw "scriptName parameter is required for Invoke-LRScript" }
                    $output = @()
                    $results = Invoke-LRScript -token $using:token -DeviceIds @($DeviceId) -scriptName $using:scriptName
                    foreach ($res in $results) {
                        $transcript = $null
                        if ($res.Success -and $res.MachineActionId) {
                            try {
                                $transcriptObj = Get-LiveResponseOutput -machineActionId $res.MachineActionId -token $using:token
                                $transcript = $transcriptObj
                            } catch {
                                $transcript = "Failed to get transcript: $($_.Exception.Message)"
                            }
                        }
                        $output += [PSCustomObject]@{
                            DeviceId        = $res.DeviceId
                            MachineActionId = $res.MachineActionId
                            Success         = $res.Success
                            Transcript      = $transcript
                        }
                    }
                    return $output
                }
                "InvokePutFile" {
                    if (-not $using:fileName) { throw "fileName parameter is required for Invoke-PutFile" }
                    $output = @()
                    $results = Invoke-PutFile -token $using:token -DeviceIds @($DeviceId) -fileName $using:fileName
                    foreach ($res in $results) {
                        $output += $res
                    }
                    return $output
                }
                "InvokeGetFile" {
                    if (-not $using:filePath) { throw "filePath parameter is required for Invoke-GetFile" }
                    $output = @()
                    $results = Invoke-GetFile -token $using:token -DeviceIds @($DeviceId) -filePath $using:filePath

                    Write-Host "Invoke-GetFile returned $($results.Count) results for DeviceId: $DeviceId"
                    foreach ($res in $results) {
                        Write-Host "Processing result: $($res | ConvertTo-Json -Compress)"
                        if ($res.Status -eq "Success" -and $res.FileUrl) {
                            try {
                                $tempFile = [System.IO.Path]::GetTempFileName()
                                Invoke-WebRequest -Uri $res.FileUrl -OutFile $tempFile -UseBasicParsing
                                $blobName = if ($res.FileName) { $res.FileName } else { "$DeviceId-$(Get-Date -Format 'yyyyMMddHHmmss').gz" }
                                $containerName = "files"
                                $ctx = New-AzStorageContext -StorageAccountName ([System.Environment]::GetEnvironmentVariable('STORAGE_ACCOUNT', 'Process')) -UseConnectedAccount
                                Write-Host "Uploading gzip file to Azure Blob Storage: $blobName in container $containerName"
                                Set-AzStorageBlobContent -Container $containerName -Blob $blobName -Context $ctx -Force -File $tempFile
                                Remove-Item $tempFile -Force

                                $output += [PSCustomObject]@{
                                    DeviceId      = $DeviceId
                                    Success       = $true
                                    BlobName      = $blobName
                                    ContainerName = $containerName
                                    FileUrl       = $res.FileUrl
                                }
                            } catch {
                                if ($tempFile -and (Test-Path $tempFile)) { Remove-Item $tempFile -Force }
                                $output += [PSCustomObject]@{
                                    DeviceId = $DeviceId
                                    Success  = $false
                                    Error    = "Failed to upload gzip file to blob storage: $($_.Exception.Message)"
                                    FileUrl  = $res.FileUrl
                                }
                            }
                        } else {
                            $output += [PSCustomObject]@{
                                DeviceId = $DeviceId
                                Success  = $false
                                Error    = $res.Error
                                FileUrl  = $res.FileUrl
                            }
                        }
                    }
                    return $output
                }
                default {
                    throw "Invalid function specified: $using:Function"
                }
            }
        } catch {
            # Handle and log errors for each device
            Write-Host "Error processing DeviceId: $DeviceId"
            Write-Host "Exception: $($_.Exception.Message)"
            return [PSCustomObject]@{
                DeviceId = $DeviceId
                Success  = $false
                Error    = $_.Exception.Message
            }
        }
    } -ThrottleLimit $throttleLimit

    # No need to flatten, just use the results directly
    $finalResults = $orchestratorResults
    
    # Return the results as the HTTP response
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body = $finalResults | ConvertTo-Json -Depth 100
    })
}
catch {
    # Handle any unhandled exceptions in the function app
    Write-Host "Unhandled exception: $($_.Exception.Message)"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body = "Error executing function: $($_.Exception.Message)"
    })
}


