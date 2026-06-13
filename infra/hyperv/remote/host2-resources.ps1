$os = Get-CimInstance Win32_OperatingSystem
$vm = Get-VM rhl-acquired-cah
[pscustomobject]@{
  Host2_TotalRAM_GB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB,1)
  Host2_FreeRAM_GB  = [math]::Round($os.FreePhysicalMemory/1MB,1)
  VM_State          = $vm.State
  VM_AssignedGB     = [math]::Round($vm.MemoryAssigned/1GB,2)
  VM_DemandGB       = [math]::Round($vm.MemoryDemand/1GB,2)
  VM_Uptime         = $vm.Uptime.ToString()
} | Format-List
