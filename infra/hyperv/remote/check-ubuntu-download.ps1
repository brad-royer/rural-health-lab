# Runs ON Host #2 (PRAETORIAN) via Invoke-Host2.ps1. Reports BITS download
# progress for the Ubuntu ISO and, once transferred, finalizes it
# (Complete-BitsTransfer moves it from .tmp to the destination).
$ErrorActionPreference = 'Stop'
$jobName = 'rhl-ubuntu-iso'
$dest = 'C:\ISOs\ubuntu-24.04.4-live-server-amd64.iso'

$job = Get-BitsTransfer -Name $jobName -ErrorAction SilentlyContinue
if (-not $job) {
    if (Test-Path $dest) {
        "COMPLETE: $([math]::Round((Get-Item $dest).Length/1GB,2)) GB at $dest"
    } else {
        "NO JOB and no file - download not started?"
    }
    return
}

$pct = if ($job.BytesTotal -gt 0) { [math]::Round(100 * $job.BytesTransferred / $job.BytesTotal, 1) } else { 0 }
"JobState=$($job.JobState)  $pct%  ($([math]::Round($job.BytesTransferred/1GB,2))/$([math]::Round($job.BytesTotal/1GB,2)) GB)"

if ($job.JobState -eq 'Transferred') {
    Complete-BitsTransfer -BitsJob $job
    "COMPLETE: finalized to $dest ($([math]::Round((Get-Item $dest).Length/1GB,2)) GB)"
} elseif ($job.JobState -in 'Error','TransientError') {
    "ERROR: $($job.Errordescription)"
}
