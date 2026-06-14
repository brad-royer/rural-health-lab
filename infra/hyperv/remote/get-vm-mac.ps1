Get-VMNetworkAdapter -VMName rhl-acquired-cah |
  Select-Object VMName, SwitchName, MacAddress, @{n='Status';e={$_.Status}} | Format-List
(Get-VM rhl-acquired-cah | Select-Object Name, State, @{n='Uptime';e={$_.Uptime}}) | Format-List
