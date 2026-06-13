# Runs ON Host #2 (PRAETORIAN) via Invoke-Host2.ps1. Read-only. Lists ALL
# physical network adapters regardless of status, to determine whether a
# wired Ethernet port exists (even if currently disconnected) for a proper
# Hyper-V external vSwitch - Wi-Fi external switches don't bridge reliably.

Get-NetAdapter -Physical |
    Select-Object Name, InterfaceDescription, Status, MediaType,
        @{ n = 'LinkSpeed'; e = { $_.LinkSpeed } } |
    Sort-Object Status |
    Format-Table -AutoSize | Out-String
