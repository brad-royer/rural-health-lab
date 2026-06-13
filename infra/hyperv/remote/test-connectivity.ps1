# Runs ON Host #2 (PRAETORIAN) via Invoke-Host2.ps1. Confirms the WinRM path
# works and gathers the Host #2 side of the Phase 3a Step-0 inventory:
# elevation (UAC token), capacity, OS, Hyper-V availability, and whether the
# host is genuinely idle (Known Lessons #8 - nothing should exist here yet).

$cs  = Get-CimInstance Win32_ComputerSystem
$os  = Get-CimInstance Win32_OperatingSystem
$cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum

$hyperv = [bool](Get-Command Get-VM -ErrorAction SilentlyContinue)
$vmCount = 'n/a (Hyper-V not available)'
$switches = 'n/a'
if ($hyperv) {
    try   { $vmCount = (Get-VM -ErrorAction Stop | Measure-Object).Count }
    catch { $vmCount = "Get-VM error: $($_.Exception.Message)" }
    try   { $switches = ((Get-VMSwitch -ErrorAction Stop |
                ForEach-Object { "$($_.Name) [$($_.SwitchType)]" }) -join '; ') }
    catch { $switches = "Get-VMSwitch error: $($_.Exception.Message)" }
    if (-not $switches) { $switches = '(none)' }
}

$isElevated = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

[pscustomobject]@{
    Hostname        = $env:COMPUTERNAME
    RemoteElevated  = $isElevated
    OS              = $os.Caption
    TotalRAM_GB     = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    FreeRAM_GB      = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    LogicalCPUs     = $cpu
    HyperVAvailable = $hyperv
    ExistingVMs     = $vmCount
    ExistingSwitches = $switches
} | Format-List
