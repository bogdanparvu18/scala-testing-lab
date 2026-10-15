# Dot-source: . .\scripts\windows\Read-PostgresPassword.ps1
#Requires -Version 5.1
$labSecret = Read-Host 'PostgreSQL password for scala_lab' -AsSecureString
if ($labSecret.Length -eq 0) { $labSecret.Dispose(); throw 'An empty application password is not accepted.' }
$labSecretPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($labSecret)
try {
    $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($labSecretPointer)
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($labSecretPointer)
    $labSecret.Dispose()
    Remove-Variable labSecretPointer, labSecret -ErrorAction SilentlyContinue
}
Write-Host 'Application password set only for this PowerShell process and its child processes.'
