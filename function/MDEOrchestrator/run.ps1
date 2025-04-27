# MDEOrchestrator Function App
# 0.0.1

using namespace System.Net

param($Request)

try {
    $TenantId   = Get-RequestParam -Name "TenantId"   -Request $Request
    $Function   = Get-RequestParam -Name "Function"   -Request $Request
    $DeviceIds  = Get-RequestParam -Name "DeviceIds"  -Request $Request
    $allDevices = Get-RequestParam -Name "allDevices" -Request $Request
    $Filter     = Get-RequestParam -Name "Filter"     -Request $Request
    $scriptName = Get-RequestParam -Name "scriptName" -Request $Request
    $folderName = Get-RequestParam -Name "folderName" -Request $Request
    $filePath   = Get-RequestParam -Name "filePath"   -Request $Request
    $fileName   = Get-RequestParam -Name "fileName"   -Request $Request
    $StorageAccountName = Get-RequestParam -Name "StorageAccountName" -Request $Request

    $spnId        = [System.Environment]::GetEnvironmentVariable('SPNID', 'Process')
    $keyVaultName = [System.Environment]::GetEnvironmentVariable('AZURE_KEYVAULT', 'Process')
    $token        = Connect-MDE -TenantId $TenantId -SpnId $spnId -keyVaultName $keyVaultName

    # Get all devices if requested
    if ($allDevices -eq $true) {
        Write-Host "Getting all devices"
        $machines = Get-Machines -token $token | ConvertFrom-Json
        if ($null -ne $machines) {
            $DeviceIds = @($machines | ForEach-Object { $_.Id })
        } else {
            $DeviceIds = @()
        }
        Write-Host "Machines returned: $($machines.Count)"
        Write-Host "DeviceIds: $($DeviceIds -join ' ')"
    }
    # If a filter is specified (and not all devices), get filtered devices
    elseif ($null -ne $Filter -and $Filter -ne "") {
        Write-Host "Getting devices with filter: $Filter"
        $machines = Get-Machines -token $token -Filter $Filter | ConvertFrom-Json
        if ($null -ne $machines) {
            $DeviceIds = @($machines | ForEach-Object { $_.Id })
        } else {
            $DeviceIds = @()
        }
        Write-Host "Machines returned: $($machines.Count)"
        Write-Host "DeviceIds: $($DeviceIds -join ' ')"
    }

    # Normalize $DeviceIds to always be an array of strings
    if ($null -eq $DeviceIds) {
        $DeviceIds = @()
    } elseif ($DeviceIds -is [string]) {
        $DeviceIds = $DeviceIds -split '[\s,;]+' | Where-Object { $_ -ne "" }
    } elseif ($DeviceIds -is [System.Collections.IEnumerable]) {
        $DeviceIds = @($DeviceIds | ForEach-Object { "$_" } | Where-Object { $_ -ne "" })
    } else {
        $DeviceIds = @("$DeviceIds")
    }

    if ($DeviceIds.Count -eq 0) {
        Write-Host "No DeviceIds to process."
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body = "No DeviceIds to process."
        })
        return
    }

    $throttleLimit = 10

    # Use ForEach-Object -Parallel for concurrent orchestration
    $orchestratorResults = $DeviceIds | ForEach-Object -Parallel {
        param($_)
        $DeviceId = $_
        Import-Module "$using:PSScriptRoot\..\MDEAutomator\MDEAutomator.psm1" -Force
        try {
            switch ($using:Function) {
                "InvokeUploadLR" {
                    if (-not $using:filePath) { throw "filePath parameter is required for Invoke-UploadLR" }
                    $result = Invoke-UploadLR -token $using:token -filePath -$using:filePath
                    return [PSCustomObject]@{
                        Success  = $true
                        Result   = $result
                    }
                }
                "InvokeLRScript" {
                    if (-not $using:scriptName) { throw "scriptName parameter is required for Invoke-LRScript" }
                    $jsonResult = Invoke-LRScript -token $using:token -DeviceIds @($DeviceId) -scriptName $using:scriptName
                    $results = $jsonResult | ConvertFrom-Json
                    $output = @()
                    foreach ($res in $results) {
                        $isSuccess = $res.Success
                        $output += [PSCustomObject]@{
                            DeviceId        = $DeviceId
                            MachineActionId = $res.MachineActionId
                            Success         = $isSuccess
                        }
                    }
                    return $output
                }
                "InvokePutFile" {
                    if (-not $using:fileName) { throw "fileName parameter is required for Invoke-PutFile" }
                    $result = Invoke-PutFile -token $using:token -DeviceIds @($DeviceId) -fileName $using:fileName
                    return [PSCustomObject]@{
                        DeviceId = $DeviceId
                        Success  = $true
                        Result   = $result
                    }
                }
                "InvokeGetFile" {
                    if (-not $using:filePath) { throw "filePath parameter is required for Invoke-GetFile" }
                    $downloadUri = Invoke-GetFile -token $using:token -DeviceIds @($DeviceId) -filePath $using:filePath

                    if ($downloadUri) {
                        try {
                            # Download the file from the returned URI
                            $tempFile = [System.IO.Path]::GetTempFileName()
                            Invoke-WebRequest -Uri $downloadUri -OutFile $tempFile

                            # Generate a blob name
                            $timestamp = Get-Date -Format "yyyyMMddHHmmss"
                            $blobName = "$DeviceId-$timestamp.zip"

                            if (-not $StorageAccountName -or $StorageAccountName -eq "") {
                                $StorageAccountName = [System.Environment]::GetEnvironmentVariable('STORAGE_ACCOUNT', 'Process')
                            }

                            # Upload to Azure Blob Storage 
                            $ctx = New-AzStorageContext -StorageAccountName $using:StorageAccountName -UseConnectedAccount
                            $containerName = "files"
                            Set-AzStorageBlobContent -File $tempFile -Container $containerName -Blob $blobName -Context $ctx -Force

                            # Remove temp file
                            Remove-Item $tempFile -Force

                            return [PSCustomObject]@{
                                DeviceId = $DeviceId
                                Success  = $true
                                BlobName = $blobName
                                ContainerName = $containerName
                                DownloadUri = $downloadUri
                            }
                        } catch {
                            return [PSCustomObject]@{
                                DeviceId = $DeviceId
                                Success  = $false
                                Error    = "Failed to upload file to blob storage: $($_.Exception.Message)"
                                DownloadUri = $downloadUri
                            }
                        }
                    } else {
                        return [PSCustomObject]@{
                            DeviceId = $DeviceId
                            Success  = $false
                            Error    = "No download URI returned from Invoke-GetFile"
                        }
                    }
                }
                default {
                    throw "Invalid function specified: $using:Function"
                }
            }
        } catch {
            Write-Host "Error processing DeviceId: $DeviceId"
            Write-Host "Exception: $($_.Exception.Message)"
            return [PSCustomObject]@{
                DeviceId = $DeviceId
                Success  = $false
                Error    = $_.Exception.Message
            }
        }
    } -ThrottleLimit $throttleLimit

    $flatResults = @()
    foreach ($r in $orchestratorResults) {
        if ($r -is [System.Collections.IEnumerable]) {
            $flatResults += $r
        } else {
            $flatResults += @($r)
        }
    }

    Write-Host "Final Orchestrator Results: $($flatResults | ConvertTo-Json -Depth 100)"

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body = $flatResults | ConvertTo-Json -Depth 100
    })
}
catch {
    Write-Host "Unhandled exception: $($_.Exception.Message)"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body = "Error executing function: $($_.Exception.Message)"
    })
}


