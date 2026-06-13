# Runs ON Host #2 (PRAETORIAN) via Invoke-Host2.ps1. Starts an asynchronous
# BITS download of the Ubuntu Server 24.04 LTS live-server ISO to C:\ISOs.
# BITS runs in its own service, so it survives WinRM session disconnects; poll
# with check-ubuntu-download.ps1. Idempotent: skips if the ISO already exists
# at the expected size, and reuses an in-flight job.
$ErrorActionPreference = 'Stop'

$url  = 'https://releases.ubuntu.com/24.04/ubuntu-24.04.4-live-server-amd64.iso'
$dest = 'C:\ISOs\ubuntu-24.04.4-live-server-amd64.iso'
$jobName = 'rhl-ubuntu-iso'

New-Item -ItemType Directory -Force -Path C:\ISOs | Out-Null

if (Test-Path $dest) {
    $sizeGB = [math]::Round((Get-Item $dest).Length / 1GB, 2)
    if ($sizeGB -gt 2.5) { "ISO already present ($sizeGB GB) - skipping download."; return }
    "Partial/odd ISO present ($sizeGB GB); removing and re-downloading."
    Remove-Item $dest -Force
}

$existing = Get-BitsTransfer -Name $jobName -ErrorAction SilentlyContinue
if ($existing) { "BITS job '$jobName' already exists: $($existing.JobState)"; return }

Import-Module BitsTransfer
$job = Start-BitsTransfer -Source $url -Destination $dest -DisplayName $jobName `
    -Asynchronous -Priority Foreground
"Started BITS job '$($job.DisplayName)': $($job.JobState)"
