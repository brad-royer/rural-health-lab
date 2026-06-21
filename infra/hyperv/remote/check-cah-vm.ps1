$vm = Get-VM rhl-acquired-cah -ErrorAction SilentlyContinue
if (-not $vm) { "VM not found"; return }
"$($vm.Name): State=$($vm.State) Uptime=$($vm.Uptime)"
$mac = (Get-VMNetworkAdapter -VMName rhl-acquired-cah).MacAddress
"MAC=$mac SwitchName=$((Get-VMNetworkAdapter -VMName rhl-acquired-cah).SwitchName)"
