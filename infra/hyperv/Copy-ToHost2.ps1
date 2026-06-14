<#
.SYNOPSIS
  Phase 3a control-plane helper: copy a local file to Host #2 (PRAETORIAN)
  over a WinRM PSSession, creating the destination directory. Used to stage
  the seed ISO and New-LabVM.ps1 onto Host #2's local disk (Add-VMDvdDrive
  can't read \\wsl... paths, so files must be local to the target host).

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File ...\Copy-ToHost2.ps1 `
    -Source '\\wsl.localhost\Ubuntu\...\seed.iso' `
    -Destination 'C:\ISOs\seed-rhl-acquired-cah.iso' -CredPath '...\.secrets\host2-cred.xml'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination,
    [string]$Host2 = '192.168.1.115',
    [string]$CredPath
)
$ErrorActionPreference = 'Stop'
if (-not $CredPath) {
    $base = if ($PSScriptRoot) { $PSScriptRoot }
            elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath }
            else { (Get-Location).Path }
    $CredPath = Join-Path $base '.secrets\host2-cred.xml'
}
if (-not (Test-Path $Source)) { throw "Source not found: $Source" }
$cred = Import-Clixml -Path $CredPath
$sess = New-PSSession -ComputerName $Host2 -Credential $cred
try {
    $destDir = Split-Path -Parent $Destination
    Invoke-Command -Session $sess -ArgumentList $destDir {
        param($d) New-Item -ItemType Directory -Force -Path $d | Out-Null
    }
    Copy-Item -ToSession $sess -Path $Source -Destination $Destination -Force
    Invoke-Command -Session $sess -ArgumentList $Destination {
        param($p) Get-Item $p |
            Select-Object FullName, @{ n = 'MB'; e = { [math]::Round($_.Length / 1MB, 2) } }
    }
} finally {
    Remove-PSSession $sess
}
