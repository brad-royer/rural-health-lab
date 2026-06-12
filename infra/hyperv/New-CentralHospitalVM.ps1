<#
.SYNOPSIS
  Provisions the Phase 2.1 central-hospital VM (rhl-central-hospital) on
  Hyper-V (Host #1). See docs/phase2-kickoff-prompt.md (work item 2.1) and
  docs/runbooks/phase2-vm-baseline.md.

.DESCRIPTION
  Creates a Generation 2 VM with Dynamic Memory (4/2/16 GB by default),
  attaches an Ubuntu Server 24.04 LTS install ISO plus the cloud-init
  autoinstall seed ISO built by cloud-init/build-seed-iso.sh, and starts it
  for unattended install (Ubuntu + Docker + Compose, per
  cloud-init/user-data.template.yaml).

  Hyper-V management requires an elevated (Administrator) PowerShell
  session — run this script accordingly. No Terraform/Ansible (Hard Rule
  #6 in docs/phase2-kickoff-prompt.md): this is the PowerShell-script-plus-
  runbook path for Phase 2 VM provisioning.

.PARAMETER UbuntuIsoPath
  Path to the Ubuntu Server 24.04 LTS "live-server" install ISO. Download
  and verify per docs/runbooks/phase2-vm-baseline.md.

.PARAMETER SeedIsoPath
  Path to the cloud-init seed ISO produced by
  infra/hyperv/cloud-init/build-seed-iso.sh.

.EXAMPLE
  .\New-CentralHospitalVM.ps1 `
    -UbuntuIsoPath D:\ISOs\ubuntu-24.04.1-live-server-amd64.iso `
    -SeedIsoPath \\wsl.localhost\Ubuntu\home\bradr\projects\rural-health-lab\infra\hyperv\cloud-init\.generated\seed.iso
#>

[CmdletBinding()]
param(
    [string]$VMName = "rhl-central-hospital",
    [string]$VMPath = "D:\HyperV\rhl-central-hospital",
    [int]$VhdSizeGB = 80,

    [Parameter(Mandatory = $true)]
    [string]$UbuntuIsoPath,

    [Parameter(Mandatory = $true)]
    [string]$SeedIsoPath,

    [string]$SwitchName = "Internet Switch",
    [int]$ProcessorCount = 4,
    [int]$MemoryStartupGB = 4,
    [int]$MemoryMinimumGB = 2,
    [int]$MemoryMaximumGB = 16
)

$ErrorActionPreference = "Stop"

# Hyper-V cmdlets fail with permission errors (not a clean "access denied"
# exception) when not elevated — check explicitly and fail fast.
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$isElevated = (New-Object Security.Principal.WindowsPrincipal($currentUser)).
    IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isElevated) {
    throw "Run this script from an elevated (Administrator) PowerShell session — Hyper-V management requires it."
}

foreach ($isoPath in @($UbuntuIsoPath, $SeedIsoPath)) {
    if (-not (Test-Path -LiteralPath $isoPath)) {
        throw "File not found: $isoPath"
    }
}

if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    throw "VM '$VMName' already exists. Remove it first (see Rollback in docs/runbooks/phase2-vm-baseline.md) or pass a different -VMName."
}

if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    throw "Hyper-V switch '$SwitchName' not found. Run Get-VMSwitch to list available switches."
}

New-Item -ItemType Directory -Path $VMPath -Force | Out-Null
$vhdPath = Join-Path $VMPath "$VMName.vhdx"

Write-Host "Creating $VhdSizeGB GB dynamic VHDX at $vhdPath"
New-VHD -Path $vhdPath -SizeBytes ([int64]$VhdSizeGB * 1GB) -Dynamic | Out-Null

Write-Host "Creating VM '$VMName' (Gen2, $ProcessorCount vCPU, switch '$SwitchName')"
$vm = New-VM -Name $VMName -Generation 2 `
    -MemoryStartupBytes ([int64]$MemoryStartupGB * 1GB) `
    -VHDPath $vhdPath -Path $VMPath -SwitchName $SwitchName

Set-VMMemory -VM $vm -DynamicMemoryEnabled $true `
    -MinimumBytes ([int64]$MemoryMinimumGB * 1GB) `
    -MaximumBytes ([int64]$MemoryMaximumGB * 1GB) `
    -StartupBytes ([int64]$MemoryStartupGB * 1GB)

Set-VMProcessor -VM $vm -Count $ProcessorCount

# Ubuntu 24.04's shim is signed for the Microsoft UEFI CA — keep Secure Boot
# on rather than disabling it.
Set-VMFirmware -VM $vm -SecureBootTemplate "MicrosoftUEFICertificateAuthority"

$installDvd = Add-VMDvdDrive -VM $vm -Path $UbuntuIsoPath -Passthru
Add-VMDvdDrive -VM $vm -Path $SeedIsoPath | Out-Null
Set-VMFirmware -VM $vm -FirstBootDevice $installDvd

Write-Host "Starting VM '$VMName' for unattended install..."
Start-VM -VM $vm

Write-Host ""
Write-Host "Done. Next steps:"
Write-Host "  - Hyper-V Manager > $VMName > Connect, to watch the autoinstall (~10-20 min, longer on first boot)."
Write-Host "  - Once it reboots and settles, find its IP:"
Write-Host "      (Get-VM $VMName | Get-VMNetworkAdapter).IPAddresses"
Write-Host "  - SSH in with the key from infra/hyperv/cloud-init/.generated/:"
Write-Host "      ssh -i infra\hyperv\cloud-init\.generated\id_ed25519_central-hospital ubuntu@<ip>"
Write-Host "  - Record before/after host RAM/CPU for ADR 0004 (Gate A)."
