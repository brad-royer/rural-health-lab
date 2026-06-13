<#
.SYNOPSIS
  Phase 3a control-plane driver: run a PowerShell script on Host #2
  (PRAETORIAN) over WinRM, using the credential saved by
  Register-Host2-ControlPlane.ps1.

.DESCRIPTION
  Lets the agent (WSL2 powershell.exe, non-elevated, running as the same
  Windows user who saved the credential) drive Host #2 remotely for the rest
  of Phase 3a - vSwitch, addressing, firewall - without further hands-on
  steps. The remote logic is authored as an ordinary .ps1 under
  infra/hyperv/remote/ and shipped via Invoke-Command, so there is no
  shell-quoting to fight.

  Remoting needs admin on the TARGET (supplied by the credential), not on the
  client - so this runs fine non-elevated on Host #1.

.PARAMETER ScriptFile
  Path to a .ps1 whose contents run ON Host #2.

.PARAMETER ArgumentList
  Optional positional args passed to that script's param() block.

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File <repo>\infra\hyperv\Invoke-Host2.ps1 `
    -ScriptFile <repo>\infra\hyperv\remote\test-connectivity.ps1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ScriptFile,
    [object[]]$ArgumentList = @(),
    [string]$Host2 = '192.168.1.200',
    [string]$CredPath
)

$ErrorActionPreference = 'Stop'

# Resolve the credential path without relying on $PSScriptRoot, which comes
# back empty when this script is launched via -File over a UNC (\\wsl...) path.
if (-not $CredPath) {
    $base = if ($PSScriptRoot) { $PSScriptRoot }
            elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath }
            else { (Get-Location).Path }
    $CredPath = Join-Path $base '.secrets\host2-cred.xml'
}
if (-not (Test-Path $CredPath)) {
    throw "Credential not found at $CredPath - run Register-Host2-ControlPlane.ps1 first."
}
$cred = Import-Clixml -Path $CredPath
$sb = [scriptblock]::Create((Get-Content -Raw -Path $ScriptFile))
Invoke-Command -ComputerName $Host2 -Credential $cred -ScriptBlock $sb -ArgumentList $ArgumentList
