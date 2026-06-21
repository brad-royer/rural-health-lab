<#
.SYNOPSIS
  Phase 3b.6 / Gate N: re-point the HIE LAN boundary at the OAuth gateway and
  expose Keycloak to the LAN. Run ELEVATED on Host #1 (CENTURION). Supersedes
  Expose-HAPI-ToLAN.ps1 (which exposed HAPI directly — now gated).

.DESCRIPTION
  - LAN :8080 now forwards to the HIE OAuth **gateway** (WSL :8085), not HAPI.
    Participants writing to 192.168.1.176:8080 must present a valid Keycloak
    token; unauthenticated writes get 401. HAPI's own WSL :8080 stays for
    internal control-plane reads (not LAN-exposed).
  - LAN :8090 forwards to Keycloak (WSL :8090) so the acquired CAH's Mirth
    (Host #2) can obtain client_credentials tokens.
  Re-run after a reboot/WSL restart (the WSL IP is volatile).

.PARAMETER AllowSubnet
  CIDR allowed inbound. Default the lab LAN 192.168.1.0/24.
#>
[CmdletBinding()]
param([string]$AllowSubnet = '192.168.1.0/24')
$ErrorActionPreference = 'Stop'
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run elevated (Administrator).' }

$wslIp = (wsl hostname -I).Trim().Split(' ')[0]
if (-not $wslIp) { throw 'Could not determine WSL IP (is WSL running?).' }
Write-Host "WSL2 IP: $wslIp" -ForegroundColor Cyan

# :8080 LAN -> gateway (WSL :8085). Re-point (drop any prior HAPI-direct proxy).
netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=8080 2>$null | Out-Null
netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=8080 `
    connectaddress=$wslIp connectport=8085 | Out-Null
Write-Host "portproxy: 0.0.0.0:8080 -> ${wslIp}:8085 (OAuth gateway)" -ForegroundColor Green

# :8090 LAN -> Keycloak (WSL :8090).
netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=8090 2>$null | Out-Null
netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=8090 `
    connectaddress=$wslIp connectport=8090 | Out-Null
Write-Host "portproxy: 0.0.0.0:8090 -> ${wslIp}:8090 (Keycloak)" -ForegroundColor Green

foreach ($p in 8080, 8090) {
    $rule = "rhl-hie-$p"
    Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName $rule -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort $p -RemoteAddress $AllowSubnet -Profile Any | Out-Null
}
Write-Host "firewall: allow TCP 8080,8090 inbound from $AllowSubnet" -ForegroundColor Green

$lan = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -like '192.168.1.*' } | Select-Object -First 1).IPAddress
Write-Host ""
Write-Host "HIE boundary (gateway): http://${lan}:8080/fhir  (token required)" -ForegroundColor Yellow
Write-Host "Keycloak (LAN):         http://${lan}:8090/realms/rural-health-hie" -ForegroundColor Yellow
