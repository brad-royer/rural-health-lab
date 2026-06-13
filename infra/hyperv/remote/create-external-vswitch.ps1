# Runs ON Host #2 (PRAETORIAN) via Invoke-Host2.ps1. Creates the Hyper-V
# external vSwitch the OpenEMR VM attaches to, bound to a WIRED Ethernet NIC
# so VMs pull a real LAN (192.168.1.x) DHCP lease - matching Host #1's
# topology. Idempotent: reuses an existing external switch on the same NIC.
#
# Safe to run over a Wi-Fi WinRM session: it binds the Ethernet adapter, not
# Wi-Fi, so the management connection is not interrupted. AllowManagementOS is
# left $true so the host keeps connectivity on the wired NIC too.
param(
    [string]$NicName,
    [string]$SwitchName = 'rhl-lan-external'
)
$ErrorActionPreference = 'Stop'

# Default to the first Up wired (802.3) adapter.
if (-not $NicName) {
    $eth = Get-NetAdapter -Physical |
        Where-Object { $_.MediaType -eq '802.3' -and $_.Status -eq 'Up' } |
        Select-Object -First 1
    if (-not $eth) {
        throw 'No wired Ethernet adapter is Up. Connect a cable to the LAN and retry.'
    }
    $NicName = $eth.Name
}
$nicDesc = (Get-NetAdapter -Name $NicName).InterfaceDescription

# Idempotency: a switch already bound to this NIC, or by this name.
$onNic = Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue |
    Where-Object { $_.NetAdapterInterfaceDescription -eq $nicDesc }
if ($onNic) {
    Write-Host "External switch already on '$NicName': $($onNic.Name)" -ForegroundColor Green
    return
}
if (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue) {
    Write-Host "Switch '$SwitchName' already exists." -ForegroundColor Green
    return
}

Write-Host "Creating external vSwitch '$SwitchName' on '$NicName' ($nicDesc)..." -ForegroundColor Cyan
New-VMSwitch -Name $SwitchName -NetAdapterName $NicName -AllowManagementOS $true |
    Select-Object Name, SwitchType, NetAdapterInterfaceDescription |
    Format-List
Write-Host "Done." -ForegroundColor Green
