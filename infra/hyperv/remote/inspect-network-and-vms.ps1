# Runs ON Host #2 (PRAETORIAN) via Invoke-Host2.ps1. Read-only. Gathers the
# facts needed to choose an external-vSwitch NIC (Gate J) and to size the
# OpenEMR VM against real free headroom (Gate H): physical NICs, the LAN IPs,
# the existing VMs' actual memory use, and current vSwitch bindings.

"=== Physical NICs (Up) ==="
Get-NetAdapter -Physical |
    Where-Object Status -eq 'Up' |
    Select-Object Name, InterfaceDescription, LinkSpeed, Status |
    Format-Table -AutoSize | Out-String

"=== IPv4 addresses (non-APIPA) ==="
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notlike '169.254.*' } |
    Select-Object InterfaceAlias, IPAddress, PrefixLength |
    Sort-Object InterfaceAlias |
    Format-Table -AutoSize | Out-String

"=== Existing VMs (memory) ==="
Get-VM | Select-Object Name, State,
    @{ n = 'AssignedGB'; e = { [math]::Round($_.MemoryAssigned / 1GB, 1) } },
    @{ n = 'DemandGB';   e = { [math]::Round($_.MemoryDemand / 1GB, 1) } },
    @{ n = 'DynMax_GB';  e = { if ($_.DynamicMemoryEnabled) { [math]::Round($_.MemoryMaximum / 1GB, 1) } else { 'static' } } } |
    Format-Table -AutoSize | Out-String

"=== Sum of memory assigned to running VMs ==="
$running = Get-VM | Where-Object State -eq 'Running'
("{0} running VM(s), assigned total {1} GB" -f
    $running.Count,
    [math]::Round((($running | Measure-Object MemoryAssigned -Sum).Sum) / 1GB, 1))

"=== VMSwitches ==="
Get-VMSwitch |
    Select-Object Name, SwitchType, NetAdapterInterfaceDescription |
    Format-Table -AutoSize | Out-String
