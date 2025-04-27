# Check if the TrustedSigning module is installed
if (-not (Get-Module -ListAvailable -Name TrustedSigning)) {
    Install-Module -Name TrustedSigning -ErrorAction Stop -Force
}

Import-Module -Name TrustedSigning -ErrorAction Stop -Force

if (-not (Get-Module -ListAvailable -Name Az)) {
    Install-Module -Name Az -ErrorAction Stop -Force
}

Connect-AzAccount -ErrorAction Stop

# Set the specific subscription (replace with your subscription ID)
$subscriptionId = "<your-subscription-id>"
Set-AzContext -Subscription $subscriptionId -ErrorAction Stop

$endpoint = "<your-endpoint-url>"
$codeSigningAccountName = "<your-codesigning-account>"
$certificateProfileName = "<your-certificate-profile>"
$fileDigest = "SHA256"
$timestampRfc3161 = "http://timestamp.acs.microsoft.com"
$timestampDigest = "SHA256"

$unsignedFolder = "<path-to-unsigned-folder>"
$files = Get-ChildItem -Path $unsignedFolder -Filter *.ps1

foreach ($file in $files) {
    Invoke-TrustedSigning `
        -Endpoint $endpoint `
        -CodeSigningAccountName $codeSigningAccountName `
        -CertificateProfileName $certificateProfileName `
        -Files $file.FullName `
        -FileDigest $fileDigest `
        -TimestampRfc3161 $timestampRfc3161 `
        -TimestampDigest $timestampDigest

    Write-Host "Signed file: $($file.FullName)"
}

Write-Host "All scripts have been signed successfully."