"=== external switches ==="
Get-VMSwitch -SwitchType External | Select-Object Name, NetAdapterInterfaceDescription | Format-Table -AutoSize | Out-String
"=== host vEthernet IPs on the new switch ==="
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.InterfaceAlias -like '*rhl-lan-external*' -and $_.IPAddress -notlike '169.*' } |
    Select-Object InterfaceAlias, IPAddress, PrefixLength | Format-Table -AutoSize | Out-String
