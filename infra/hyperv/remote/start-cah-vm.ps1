Start-VM rhl-acquired-cah -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
$vm = Get-VM rhl-acquired-cah
"rhl-acquired-cah: State=$($vm.State)"
