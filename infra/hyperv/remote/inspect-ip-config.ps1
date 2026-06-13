# Runs ON Host #2 (PRAETORIAN) via Invoke-Host2.ps1. Read-only. Captures the
# wired NIC's full IPv4 config (address, gateway, DNS, DHCP state) so the
# external-vSwitch step can reapply a deterministic static address to the
# resulting host vEthernet - creating the switch moves the IP off the physical
# NIC and would otherwise hand us a new, unknown DHCP lease.

$eth = Get-NetAdapter -Physical |
    Where-Object { $_.MediaType -eq '802.3' -and $_.Status -eq 'Up' } |
    Select-Object -First 1
if (-not $eth) { throw 'No wired Ethernet adapter is Up.' }

$ip  = Get-NetIPAddress -InterfaceAlias $eth.Name -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
$gw  = (Get-NetRoute -InterfaceAlias $eth.Name -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Select-Object -First 1).NextHop
$dns = (Get-DnsClientServerAddress -InterfaceAlias $eth.Name -AddressFamily IPv4).ServerAddresses -join ','
$dhcp = (Get-NetIPInterface -InterfaceAlias $eth.Name -AddressFamily IPv4).Dhcp

[pscustomobject]@{
    Adapter     = $eth.Name
    Description = $eth.InterfaceDescription
    IPv4        = $ip.IPAddress
    PrefixLength = $ip.PrefixLength
    Gateway     = $gw
    DNS         = $dns
    DhcpEnabled = $dhcp
} | Format-List

"=== existing external vSwitches ==="
$ext = Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue
if ($ext) { $ext | Select-Object Name, NetAdapterInterfaceDescription | Format-List }
else { "(none)" }
