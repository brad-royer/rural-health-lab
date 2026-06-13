<#
.SYNOPSIS
  Phase 3a.1 bootstrap, part 1 of 2 (run ON Host #2). Enables WinRM so the
  control plane (WSL2 on Host #1 "CENTURION") can drive Host #2's Hyper-V,
  networking, and firewall remotely for the rest of Phase 3a.

.DESCRIPTION
  Host #2 (the acquired CAH's physical host) starts with no remote-management
  path from the control plane. This script, run once in an ELEVATED PowerShell
  on Host #2, turns on PowerShell Remoting (WinRM over HTTP/5985) and scopes
  the WinRM firewall rule to the lab LAN so only Host #1 can reach it.

  Lab choice: HTTP + NTLM with explicit credentials, which (in a workgroup,
  no AD) also requires adding Host #2 to TrustedHosts on Host #1 - that is
  part 2 (Register-Host2-ControlPlane.ps1). Production delta (documented in
  docs/runbooks/phase3a-cross-host-networking.md): real cross-org admin uses
  HTTPS/5986 with a real certificate and Kerberos/JEA, not HTTP + TrustedHosts.

  No Terraform/Ansible (Hard Rule #8): PowerShell-plus-runbook, same as
  Phase 2 VM provisioning.

.PARAMETER ControlPlaneSubnet
  CIDR allowed to reach WinRM on this host. Defaults to the lab LAN
  192.168.1.0/24 (the subnet the Bahmni VM DHCP'd onto). Narrow to Host #1's
  exact IP if you prefer.

.EXAMPLE
  # Elevated PowerShell on Host #2:
  .\Enable-RemoteMgmt-Host2.ps1
#>
[CmdletBinding()]
param(
    [string]$ControlPlaneSubnet = '192.168.1.0/24'
)

$ErrorActionPreference = 'Stop'

# Fail fast if not elevated - WinRM config and firewall edits need admin.
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw 'Run this in an ELEVATED PowerShell session (Administrator).'
}

Write-Host '== Enabling PowerShell Remoting (WinRM) ==' -ForegroundColor Cyan
Enable-PSRemoting -Force -SkipNetworkProfileCheck

# Scope the inbound WinRM HTTP rule to the lab LAN only, rather than leaving
# it at whatever Enable-PSRemoting defaulted to.
Write-Host "== Scoping WinRM firewall rule to $ControlPlaneSubnet ==" -ForegroundColor Cyan
Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*' -ErrorAction SilentlyContinue |
    Set-NetFirewallRule -RemoteAddress $ControlPlaneSubnet -Enabled True -Profile Any

# Report what the control plane needs to target this host.
$ip = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -like '192.168.1.*' } |
    Select-Object -First 1).IPAddress
Write-Host ''
Write-Host '== Host #2 ready for remote management ==' -ForegroundColor Green
Write-Host ("  Hostname : {0}" -f $env:COMPUTERNAME)
Write-Host ("  LAN IPv4 : {0}" -f $ip)
Write-Host ("  WinRM    : HTTP/5985, allowed from {0}" -f $ControlPlaneSubnet)
Write-Host ''
Write-Host 'Report the Hostname and LAN IPv4 back, then run part 2' -ForegroundColor Yellow
Write-Host '(Register-Host2-ControlPlane.ps1) on Host #1.' -ForegroundColor Yellow
