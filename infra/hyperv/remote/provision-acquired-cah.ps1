# Runs ON Host #2 (PRAETORIAN) via Invoke-Host2.ps1. Creates + starts the
# acquired-CAH VM by splatting Gate-H sizing to the staged generic
# New-LabVM.ps1 (single source of truth, copied to C:\rhl). ISOs are staged on
# C:\ISOs. Attaches to the external switch rhl-lan-external so the VM pulls a
# real 192.168.1.x lease.
$ErrorActionPreference = 'Stop'

$p = @{
    VMName         = 'rhl-acquired-cah'
    SwitchName     = 'rhl-lan-external'
    UbuntuIsoPath  = 'C:\ISOs\ubuntu-24.04.4-live-server-amd64.iso'
    SeedIsoPath    = 'C:\ISOs\seed-rhl-acquired-cah.iso'
    VMPath         = 'C:\HyperV\rhl-acquired-cah'
    VhdSizeGB      = 60
    ProcessorCount = 4
    MemoryStartupGB = 2
    MemoryMinimumGB = 1
    MemoryMaximumGB = 6
}
& 'C:\rhl\New-LabVM.ps1' @p
