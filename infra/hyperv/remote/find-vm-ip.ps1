# Find the acquired-CAH VM's LAN IP by its MAC, via Host #2's neighbor cache
# (no KVP daemon in the guest). Fast async ping sweep to populate ARP first.
$mac = '00-15-5D-00-18-1D'
$tasks = 1..254 | ForEach-Object {
    (New-Object System.Net.NetworkInformation.Ping).SendPingAsync("192.168.1.$_", 1000)
}
[System.Threading.Tasks.Task]::WaitAll($tasks) | Out-Null
Start-Sleep -Seconds 2
$n = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.LinkLayerAddress -eq $mac -and $_.IPAddress -like '192.168.1.*' }
if ($n) { "VM_IP=$($n.IPAddress)" }
else { "NOT FOUND; arp scan:"; arp -a | Select-String '00-15-5d-00-18-1d' }
