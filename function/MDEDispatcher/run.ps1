# MDEDispatcher Function App
# 0.0.1

using namespace System.Net

param($Request)

try {
    # Get request parameters
    $TenantId = Get-RequestParam -Name "TenantId" -Request $Request
    $Function = Get-RequestParam -Name "Function" -Request $Request
    $DeviceIds = Get-RequestParam -Name "DeviceIds" -Request $Request
    $allDevices = Get-RequestParam -Name "allDevices" -Request $Request -DefaultValue $false
    $Filter = Get-RequestParam -Name "Filter" -Request $Request
    $StorageAccountName = Get-RequestParam -Name "StorageAccountName" -Request $Request

    # Get environment variables and connect
    $spnId = [System.Environment]::GetEnvironmentVariable('SPNID', 'Process')
    $keyVaultName = [System.Environment]::GetEnvironmentVariable('AZURE_KEYVAULT', 'Process')
    $storageAccountName = $StorageAccountName
    if (-not $storageAccountName) {
        $storageAccountName = [System.Environment]::GetEnvironmentVariable('STORAGE_ACCOUNT', 'Process')
    }
    $token = Connect-MDE -TenantId $TenantId -SpnId $spnId -keyVaultName $keyVaultName

    if ($allDevices -eq $true) {
        Write-Host "Getting all devices"
        $machines = Get-Machines -token $token
        $DeviceIds = $machines.Id
    }
    elseif ($Filter) {
        Write-Host "Using provided filter: $Filter"
        $machines = Get-Machines -token $token -filter $Filter 
        $DeviceIds = $machines.Id
    }
    elseif ($DeviceIds -and $DeviceIds.Count -gt 0) {
        Write-Host "Using provided DeviceIds from request"
    }
    else {
        throw "Either allDevices must be true, or Filter/DeviceIds must be provided"
    }

    if (-not $DeviceIds -or $DeviceIds.Count -eq 0) {
        throw "No valid devices found matching the specified criteria."
    }

    $Result = [HttpStatusCode]::OK
    $throttleLimit = 10

    # Use ForEach-Object -Parallel for concurrent device actions
    $results = $DeviceIds | ForEach-Object -Parallel {
        param($_)
        $deviceId = $_
        Import-Module "$using:PSScriptRoot\..\MDEAutomator\MDEAutomator.psm1" -Force
        try {
            $actionResult = switch ($using:Function) {
                "InvokeMachineIsolation" { 
                    Invoke-MachineIsolation -token $using:token -DeviceIds $deviceId 
                }
                "InvokeFullDiskScan" { 
                    Invoke-FullDiskScan -token $using:token -DeviceIds $deviceId 
                }
                "UndoMachineIsolation" { 
                    Undo-MachineIsolation -token $using:token -DeviceIds $deviceId 
                }
                "InvokeRestrictAppExecution" { 
                    Invoke-RestrictAppExecution -token $using:token -DeviceIds $deviceId 
                }
                "UndoRestrictAppExecution" { 
                    Undo-RestrictAppExecution -token $using:token -DeviceIds $deviceId 
                }
                "InvokeMachineOffboard" { 
                    Invoke-MachineOffboard -token $using:token -DeviceIds $deviceId 
                }
                "InvokeCollectInvestigationPackage" {
                    
                    $output = @()
                    $resultObj = Invoke-CollectInvestigationPackage -token $using:token -DeviceIds $deviceId
                    
                    if ($resultObj.Status -eq "Success" -and $resultObj.PackageUri) {
                        try {
                            $tempFile = [System.IO.Path]::GetTempFileName()
                            Invoke-WebRequest -Uri $resultObj.PackageUri -OutFile $tempFile
                            $timestamp = Get-Date -Format "yyyyMMddHHmmss"
                            $blobName = "$deviceId-$timestamp-investigation.zip"
                            $ctx = New-AzStorageContext -StorageAccountName $using:StorageAccountName -UseConnectedAccount
                            $containerName = "packages"
                            Set-AzStorageBlobContent -File $tempFile -Container $containerName -Blob $blobName -Context $ctx -Force
                            Remove-Item $tempFile -Force
                
                            $output += [PSCustomObject]@{
                                DeviceId      = $deviceId
                                Success       = $true
                                BlobName      = $blobName
                                ContainerName = $containerName
                                PackageUri    = $resultObj.PackageUri
                            }
                        } catch {
                            $output += [PSCustomObject]@{
                                DeviceId   = $deviceId
                                Success    = $false
                                Error      = "Failed to upload investigation package: $($_.Exception.Message)"
                                PackageUri = $resultObj.PackageUri
                            }
                        }
                    } else {
                        $output += [PSCustomObject]@{
                            DeviceId   = $deviceId
                            Success    = $false
                            Error      = $resultObj.Error
                            PackageUri = $resultObj.PackageUri
                        }
                    }
                    return $output
                }
                default { 
                    throw "Invalid function specified: $using:Function"
                }
            }
            [PSCustomObject]@{
                DeviceId = $deviceId
                Status = "Success"
                Result = $actionResult
            }
        }
        catch {
            if ($_.Exception.Message -match '"code":\s*"ActiveRequestAlreadyExists"') {
                Write-Host "Action already in progress for device: $deviceId"
                [PSCustomObject]@{
                    DeviceId = $deviceId
                    Status = "Skipped"
                    Result = "Action already in progress"
                }
            }
            else {
                Write-Error "Error processing device $deviceId : $($_.Exception.Message)"
                [PSCustomObject]@{
                    DeviceId = $deviceId
                    Status = "Error"
                    Result = $_.Exception.Message
                }
            }
        }
    } -ThrottleLimit $throttleLimit

    $Body = $results
}
catch {
    $Result = [HttpStatusCode]::InternalServerError
    $Body = "Error executing function: $($_.Exception.Message)"
    Write-Error $_.Exception.Message
}

# Return response
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = $Result
    Body = $Body
})