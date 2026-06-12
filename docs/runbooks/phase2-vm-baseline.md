# Runbook: Phase 2.1 — Central-Hospital VM Baseline (Host #1)

Provisions the Hyper-V VM that will host Bahmni (or the Gate A fallback)
for Phase 2. See `docs/phase2-kickoff-prompt.md` (work item 2.1, Gate A)
and `docs/adr/0001-handoff.md` ("Hardware Topology"). This is increment
2.1's content; it will be folded into the generic
`docs/runbooks/participant-onboarding.md` (2.6) as the "VM baseline" step.

## Goal

A Hyper-V VM (`rhl-central-hospital`) on Host #1 running Ubuntu Server
24.04 LTS with Docker + Compose installed, reachable over the LAN, with
Host #1's RAM/CPU usage recorded before and after — the measured input to
Gate A's ADR (`docs/adr/0004-gate-a-bahmni-edition-and-sizing.md`).

## Prerequisites

- Phase 1 stack running on Host #1 / WSL2 (`v0.1.0-phase1`).
- An elevated (Administrator) PowerShell session **on Host #1 itself** —
  Hyper-V management (`New-VM`, `Get-VM`, etc.) fails with permission
  errors otherwise, including from a non-elevated `powershell.exe` invoked
  from WSL2.
- `python3 -m pip install --user pycdlib` in WSL2 (used to build the
  cloud-init seed ISO without needing `genisoimage`/root).
- An Ubuntu Server 24.04 LTS "live-server" ISO, downloaded to Host #1 and
  checksum-verified:
  - https://releases.ubuntu.com/24.04/ → `ubuntu-24.04.*-live-server-amd64.iso`
  - Verify against the published `SHA256SUMS` for that release.
  - Suggested location: `D:\ISOs\` (1.5+ TB free on Host #1's `D:`).

## Before: record Host #1 baseline

From an elevated PowerShell session on Host #1:

```powershell
Get-ComputerInfo | Select-Object OsTotalVisibleMemorySize, OsFreePhysicalMemory
Get-VM | Select-Object Name, State, MemoryAssigned, ProcessorCount
```

Record free RAM (KB) and the list of any existing VMs. As of the Phase 2.0
inventory (2026-06-12, non-elevated query): Host #1 = 63.7 GB total RAM,
~21.8 GB free, 32 logical CPUs (i9-14900KF), no VMs/switches visible
(query was non-elevated — re-run elevated for the authoritative pre-numbers).

## Automation path

1. **Build the cloud-init seed ISO** (in WSL2, from the repo root):

   ```bash
   ./infra/hyperv/cloud-init/build-seed-iso.sh
   ```

   This generates a dedicated SSH keypair and a one-time console password
   (SSH password auth is disabled) under
   `infra/hyperv/cloud-init/.generated/` (gitignored), and writes
   `seed.iso`. Re-running reuses the existing keypair.

2. **Copy the seed ISO to a local path** (elevated PowerShell on Host #1).
   `Add-VMDvdDrive` is serviced by the Hyper-V VM management service
   running as SYSTEM, which cannot authenticate to a per-user
   `\\wsl.localhost\...` mount ("network name cannot be found") - the seed
   ISO must be on local disk:

   ```powershell
   Copy-Item \\wsl.localhost\<distro>\home\bradr\projects\rural-health-lab\infra\hyperv\cloud-init\.generated\seed.iso D:\ISOs\seed.iso
   ```

3. **Provision the VM** (same elevated session). The default execution
   policy blocks unsigned scripts run from a UNC path; allow it for this
   session only (does not change the system/user policy):

   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   & "\\wsl.localhost\<distro>\home\bradr\projects\rural-health-lab\infra\hyperv\New-CentralHospitalVM.ps1" `
     -UbuntuIsoPath D:\ISOs\ubuntu-24.04.1-live-server-amd64.iso `
     -SeedIsoPath D:\ISOs\seed.iso
   ```

   Defaults: `rhl-central-hospital`, Generation 2, 4 vCPU, Dynamic Memory
   4 GB startup / 2 GB min / 16 GB max, 80 GB dynamic VHDX under
   `D:\HyperV\rhl-central-hospital\`, attached to the existing "Internet
   Switch" external vSwitch (LAN-routable, 192.168.1.x).

   The script creates the VM and starts it. Unattended install (Ubuntu +
   `docker.io` + `docker-compose-v2`, per
   `cloud-init/user-data.template.yaml`) takes roughly 10-20 minutes; it
   reboots itself when done.

4. **Find the VM's IP and verify**:

   ```powershell
   (Get-VM rhl-central-hospital | Get-VMNetworkAdapter).IPAddresses
   ```

   ```bash
   ssh -i infra/hyperv/cloud-init/.generated/id_ed25519_central-hospital ubuntu@<ip>
   docker --version && docker compose version
   ```

## After: record Host #1 usage

Repeat the `Get-ComputerInfo`/`Get-VM` queries from "Before". Record:
- Host #1 free RAM before vs. after the VM is created and idle.
- The VM's own RAM/CPU usage (`free -h`, `nproc` inside the VM).

These numbers go into `docs/adr/0004-gate-a-bahmni-edition-and-sizing.md`
to confirm/revise the Bahmni Standard / Lite / vanilla OpenMRS choice.

## Manual fallback path

If you prefer not to use the script (or it fails partway):

1. Hyper-V Manager → New → Virtual Machine. Generation 2, name
   `rhl-central-hospital`, 80 GB dynamic VHDX, attach to "Internet Switch".
2. Settings → Memory → enable Dynamic Memory, 4096 MB startup / 2048 MB
   minimum / 16384 MB maximum. Settings → Processor → 4 virtual processors.
3. Settings → Security → Secure Boot template:
   "Microsoft UEFI Certificate Authority".
4. Settings → DVD Drives → attach the Ubuntu ISO (boot device #1) and the
   `seed.iso` from `infra/hyperv/cloud-init/.generated/` as a second DVD
   drive.
5. Start the VM and connect; the autoinstall proceeds unattended using the
   seed ISO. If you'd rather click through the installer by hand, omit the
   seed ISO and answer the prompts yourself, then install Docker manually:
   `sudo apt update && sudo apt install -y docker.io docker-compose-v2 && sudo usermod -aG docker $USER`.

## Validation checks

- [ ] `docker --version` and `docker compose version` succeed on the VM.
- [ ] VM is reachable via SSH from WSL2 over the LAN (confirms the
      "Internet Switch" path works for later Mirth ↔ Bahmni ↔ HAPI
      traffic in 2.4).
- [ ] Host #1 before/after RAM numbers recorded.
- [ ] Host #2 untouched (Hard Rule #4 — check `Get-VM` doesn't list
      anything created on Host #2).

## Rollback procedure

Elevated PowerShell on Host #1:

```powershell
Stop-VM rhl-central-hospital -TurnOff -Force
Remove-VM rhl-central-hospital -Force
Remove-Item -Recurse -Force D:\HyperV\rhl-central-hospital
```

In WSL2, `infra/hyperv/cloud-init/.generated/` can be deleted and
regenerated by re-running `build-seed-iso.sh` — it is gitignored and not
part of any committed state.
