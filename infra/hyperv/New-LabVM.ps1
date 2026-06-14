<#
.SYNOPSIS
  Provisions a lab VM on Hyper-V from an Ubuntu Server 24.04 LTS install ISO
  plus a cloud-init autoinstall seed ISO. Generic across hosts/participants -
  Phase 2 used it for rhl-central-hospital (Host #1); Phase 3a uses it for
  rhl-acquired-cah (Host #2). See docs/runbooks/participant-onboarding.md.

.DESCRIPTION
  Creates a Generation 2 VM with Dynamic Memory, attaches the Ubuntu install
  ISO + the seed ISO built by cloud-init/build-seed-iso.sh, and starts it for
  unattended install (Ubuntu + Docker + Compose, per
  cloud-init/user-data.template.yaml).

  Hyper-V management requires an elevated (Administrator) context - run in an
  elevated session, or remotely via Invoke-Command with an admin credential
  (the WinRM session carries a full admin token). No Terraform/Ansible (IaC
  is Phase 4): this is the PowerShell-script-plus-runbook path.

.PARAMETER VMName
  VM name (and default leaf of VMPath / VHDX name). e.g. rhl-acquired-cah.

.PARAMETER SwitchName
  Hyper-V switch to attach. Must be an EXTERNAL switch for the VM to get a LAN
  IP (e.g. rhl-lan-external on Host #2; "Internet Switch" on Host #1).

.PARAMETER UbuntuIsoPath
  Path to the Ubuntu Server 24.04 LTS "live-server" install ISO. Must be LOCAL
  to the target Windows host.

.PARAMETER SeedIsoPath
  Path to the cloud-init seed ISO from build-seed-iso.sh. Must be a LOCAL path
  on the target host - Add-VMDvdDrive is serviced by the Hyper-V management
  service as SYSTEM, which cannot read a per-user \\wsl.localhost\... mount
  ("network name cannot be found"). Copy the seed ISO to local disk first
  (Copy-Item -ToSession works over the WinRM session for a remote host).

.EXAMPLE
  # Host #2, via the control-plane WinRM driver, the seed + Ubuntu ISO already
  # staged on C:\ISOs (see docs/runbooks/phase3a-vm-baseline.md):
  .\New-LabVM.ps1 -VMName rhl-acquired-cah -SwitchName rhl-lan-external `
    -UbuntuIsoPath C:\ISOs\ubuntu-24.04.4-live-server-amd64.iso `
    -SeedIsoPath C:\ISOs\seed-rhl-acquired-cah.iso `
    -MemoryStartupGB 2 -MemoryMinimumGB 1 -MemoryMaximumGB 6 -VhdSizeGB 60
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VMName,

    [Parameter(Mandatory = $true)]
    [string]$SwitchName,

    [Parameter(Mandatory = $true)]
    [string]$UbuntuIsoPath,

    [Parameter(Mandatory = $true)]
    [string]$SeedIsoPath,

    [string]$VMPath = "C:\HyperV\$VMName",
    [int]$VhdSizeGB = 60,
    [int]$ProcessorCount = 4,
    [int]$MemoryStartupGB = 2,
    [int]$MemoryMinimumGB = 1,
    [int]$MemoryMaximumGB = 6
)

$ErrorActionPreference = "Stop"

# Hyper-V cmdlets fail with permission errors (not a clean "access denied"
# exception) when not elevated - check explicitly and fail fast. Over a WinRM
# session opened with an admin credential, this reports elevated.
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$isElevated = (New-Object Security.Principal.WindowsPrincipal($currentUser)).
    IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isElevated) {
    throw "Run elevated (or via Invoke-Command with an admin credential) - Hyper-V management requires it."
}

foreach ($isoPath in @($UbuntuIsoPath, $SeedIsoPath)) {
    if (-not (Test-Path -LiteralPath $isoPath)) {
        throw "File not found on the target host: $isoPath"
    }
}

if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    throw "VM '$VMName' already exists. Remove it first or pass a different -VMName."
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

# Ubuntu 24.04's shim is signed for the Microsoft UEFI CA - keep Secure Boot
# on rather than disabling it.
Set-VMFirmware -VM $vm -SecureBootTemplate "MicrosoftUEFICertificateAuthority"

$installDvd = Add-VMDvdDrive -VM $vm -Path $UbuntuIsoPath -Passthru
Add-VMDvdDrive -VM $vm -Path $SeedIsoPath | Out-Null
Set-VMFirmware -VM $vm -FirstBootDevice $installDvd

Write-Host "Starting VM '$VMName' for unattended install..."
Start-VM -VM $vm

Write-Host ""
Write-Host "Done. Next steps:"
Write-Host "  - Open VMConnect on the target host to watch the autoinstall."
Write-Host "  - Subiquity pauses once for a 'type yes' autoinstall confirmation"
Write-Host "    (the seed-ISO path can't set the kernel cmdline) - confirm it."
Write-Host "  - After it settles, find its IP and SSH in with the generated key"
Write-Host "    (infra/hyperv/cloud-init/.generated/<vmname>/id_ed25519_<vmname>)."
