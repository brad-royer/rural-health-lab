<#
.SYNOPSIS
  Phase 3a.1 bootstrap, part 2 of 2 (run ON Host #1 / CENTURION). Lets the
  control plane reach Host #2 over WinRM and saves a Host #2 admin credential
  the agent can use non-interactively (DPAPI-encrypted, never committed).

.DESCRIPTION
  After Enable-RemoteMgmt-Host2.ps1 has run on Host #2, this script (ELEVATED
  on Host #1, once) does three things:
    1. Adds Host #2 to this client's WinRM TrustedHosts (required for
       workgroup HTTP/NTLM remoting - no AD/Kerberos in this lab).
    2. Prompts for a Host #2 local-admin credential and saves it via
       Export-Clixml to infra\hyperv\.secrets\host2-cred.xml. Export-Clixml
       encrypts with DPAPI bound to the CURRENT Windows user, so only this
       user on this machine can read it back - and it is gitignored
       (infra/hyperv/.secrets/). No plaintext secret touches the repo
       (Hard Rule #6).
    3. Round-trips Invoke-Command to prove the control plane can drive
       Host #2.

  The agent's WSL2 powershell.exe calls run as this same Windows user, so its
  scripts can Import-Clixml the credential and Invoke-Command to Host #2
  without elevation on Host #1 (remoting needs admin on the TARGET, supplied
  by the credential - not on the client).

.PARAMETER Host2
  Host #2 hostname or LAN IP, as reported by part 1.

.PARAMETER RepoRoot
  Repo root on this host, used to locate the gitignored .secrets dir.
  Defaults to two levels up from this script.

.EXAMPLE
  # Elevated PowerShell on Host #1:
  .\Register-Host2-ControlPlane.ps1 -Host2 192.168.1.240
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Host2,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw 'Run this in an ELEVATED PowerShell session (Administrator).'
}

# 0. Initialize the WinRM client stack. On a host that has never used WinRM
#    the service is stopped and the WSMan: provider doesn't expose
#    Client\TrustedHosts yet (the "Cannot find path ... does not exist"
#    error). Host #1 only needs WinRM as a *client* (to connect out), but the
#    service must be running for its config to exist. Starting it explicitly
#    also avoids the interactive "Start WinRM Service?" prompt.
Write-Host '== Initializing WinRM client ==' -ForegroundColor Cyan
if ((Get-Service WinRM).Status -ne 'Running') {
    Set-Service WinRM -StartupType Automatic
    Start-Service WinRM
}

# 1. TrustedHosts - merge, don't clobber. Treat a missing/empty node as empty.
Write-Host "== Adding $Host2 to WinRM TrustedHosts ==" -ForegroundColor Cyan
$curItem = Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction SilentlyContinue
$cur = if ($curItem) { $curItem.Value } else { '' }
$entries = @($cur -split ',' | Where-Object { $_ }) + $Host2 |
    Sort-Object -Unique
Set-Item WSMan:\localhost\Client\TrustedHosts -Value ($entries -join ',') -Force
Write-Host ("  TrustedHosts = {0}" -f ($entries -join ','))

# 2. Save the Host #2 admin credential (DPAPI, gitignored).
$secretsDir = Join-Path $RepoRoot 'infra\hyperv\.secrets'
New-Item -ItemType Directory -Force -Path $secretsDir | Out-Null
$credPath = Join-Path $secretsDir 'host2-cred.xml'
Write-Host '== Enter a Host #2 LOCAL ADMIN credential to save ==' -ForegroundColor Cyan
Write-Host '   (username form: HOST2NAME\Administrator or .\Administrator)' -ForegroundColor DarkGray
Get-Credential | Export-Clixml -Path $credPath
Write-Host ("  Saved (DPAPI, this user only): {0}" -f $credPath)

# 3. Prove it works.
Write-Host "== Testing Invoke-Command to $Host2 ==" -ForegroundColor Cyan
$cred = Import-Clixml -Path $credPath
$remote = Invoke-Command -ComputerName $Host2 -Credential $cred -ScriptBlock {
    [pscustomobject]@{ Hostname = $env:COMPUTERNAME; PSVersion = $PSVersionTable.PSVersion.ToString() }
}
Write-Host ''
Write-Host '== Remote management established ==' -ForegroundColor Green
Write-Host ("  Reached: {0} (PowerShell {1})" -f $remote.Hostname, $remote.PSVersion)
Write-Host ''
Write-Host 'The control plane can now drive Host #2. Report success and the' -ForegroundColor Yellow
Write-Host 'Host #2 hostname/IP; the agent takes over for vSwitch + firewall.' -ForegroundColor Yellow
