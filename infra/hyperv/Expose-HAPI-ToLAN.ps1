<#
.SYNOPSIS
  Phase 3a.5 / Gate J: expose the HIE's HAPI (running in WSL2 on Host #1) to
  the LAN so the acquired CAH's Mirth on Host #2 can write to it (federation
  A1). Run ELEVATED on Host #1 (CENTURION).

.DESCRIPTION
  HAPI listens inside WSL2 (NAT'd), reachable on Host #1 as localhost:8080 but
  not from other LAN hosts. This adds a netsh portproxy from the host's LAN
  :8080 to WSL2's current IP:8080, plus a Windows Firewall rule allowing
  inbound 8080 only from the lab subnet - the single controlled cross-org flow
  (CAH Mirth -> HIE HAPI). Idempotent: re-run after a WSL restart to refresh
  the (volatile) WSL IP.

  Production delta (documented in docs/runbooks/phase3a-cross-host-networking.md):
  a real HIE's FHIR server has a routable address; portproxy-over-WSL-NAT is a
  lab artifact, and the WSL IP changing on restart is its fragility.

.PARAMETER Port
  HIE HAPI port. Default 8080.

.PARAMETER AllowSubnet
  CIDR allowed inbound. Default the lab LAN 192.168.1.0/24.

.EXAMPLE
  # Elevated PowerShell on Host #1:
  .\Expose-HAPI-ToLAN.ps1
#>
[CmdletBinding()]
param(
    [int]$Port = 8080,
    [string]$AllowSubnet = '192.168.1.0/24'
)
$ErrorActionPreference = 'Stop'
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run elevated (Administrator).' }

# Current WSL IP (volatile across WSL restarts).
$wslIp = (wsl hostname -I).Trim().Split(' ')[0]
if (-not $wslIp) { throw 'Could not determine WSL IP (is WSL running?).' }
Write-Host "WSL2 IP (HAPI host): $wslIp" -ForegroundColor Cyan

# Refresh the portproxy: drop any existing listener on this port, re-add.
netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$Port 2>$null | Out-Null
netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=$Port `
    connectaddress=$wslIp connectport=$Port | Out-Null
Write-Host "portproxy: 0.0.0.0:$Port -> ${wslIp}:$Port" -ForegroundColor Green

# Firewall rule scoped to the lab subnet (idempotent).
$ruleName = "rhl-hie-hapi-$Port"
Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
    -Protocol TCP -LocalPort $Port -RemoteAddress $AllowSubnet -Profile Any | Out-Null
Write-Host "firewall: allow TCP $Port inbound from $AllowSubnet" -ForegroundColor Green

$lan = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -like '192.168.1.*' } | Select-Object -First 1).IPAddress
Write-Host ""
Write-Host "HAPI now reachable from the LAN at http://${lan}:$Port/fhir" -ForegroundColor Yellow
Write-Host "Verify from the CAH VM: curl http://${lan}:$Port/fhir/metadata" -ForegroundColor Yellow
