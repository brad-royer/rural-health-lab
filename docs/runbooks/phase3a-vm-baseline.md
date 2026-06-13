# Runbook: Phase 3a.2 — Acquired-CAH VM Baseline on Host #2

Provisions the `rhl-acquired-cah` VM (OpenEMR's host) on Host #2
(PRAETORIAN), per Gate H sizing. Second worked example of the generic
"provision the participant host" step in `participant-onboarding.md`.
Depends on 3a.1 (`phase3a-cross-host-networking.md`: WinRM channel +
`rhl-lan-external` external vSwitch).

## What's different from Phase 2 (Host #1)

Host #1's VM was provisioned by the user running PowerShell locally. Host #2
is driven **remotely from the control plane over WinRM** — almost no
hands-on steps. The tooling generalized from Phase 2:

- `infra/hyperv/New-LabVM.ps1` — the Phase 2 `New-CentralHospitalVM.ps1`
  generalized (mandatory `-VMName`/`-SwitchName`, smaller sizing defaults).
- `infra/hyperv/cloud-init/build-seed-iso.sh <hostname>` — now parameterized
  by hostname; writes to `.generated/<hostname>/`.
- `infra/hyperv/Invoke-Host2.ps1` / `Copy-ToHost2.ps1` — control-plane
  drivers (3a.1).

## Gate H — OpenEMR edition/sizing

OpenEMR is a light LAMP stack (Apache/PHP + MariaDB), far smaller than
Bahmni. Host #2 (31.9 GB, but ~8 GB free with the host's own workload; its
6 pre-existing VMs are all Off) hosts it comfortably. VM sized **Dynamic
Memory 1 GB min / 2 GB startup / 6 GB max, 4 vCPU, 60 GB dynamic VHDX** —
conservative against the available headroom; revisit if OpenEMR + MariaDB +
the CAH Mirth demand more. ADR (`docs/adr/0007-...`) records this.

## Provisioning path (control-plane driven)

1. **Build the seed ISO** (WSL): `build-seed-iso.sh rhl-acquired-cah` →
   `.generated/rhl-acquired-cah/{seed.iso, id_ed25519_rhl-acquired-cah}`.
2. **Download the Ubuntu ISO onto Host #2** (BITS, resilient, backgrounded):
   `Invoke-Host2.ps1 ... remote/start-ubuntu-download.ps1`, poll with
   `remote/check-ubuntu-download.ps1` until `COMPLETE`.
3. **Stage the small files on Host #2.** `Copy-Item -ToSession` cannot read
   a `\\wsl.localhost\...` source ("The request is not supported" — the WSL
   9P filesystem). Workaround: copy from WSL to Host #1's local C: via the
   `/mnt/c` mount first, then `Copy-ToHost2.ps1` from `C:\Temp\...`. Stages
   `seed.iso` → `C:\ISOs\seed-rhl-acquired-cah.iso` and `New-LabVM.ps1` →
   `C:\rhl\`.
4. **Create + start the VM** (over WinRM):
   `Invoke-Host2.ps1 ... remote/provision-acquired-cah.ps1` (splats Gate-H
   params to `C:\rhl\New-LabVM.ps1`, switch `rhl-lan-external`).
5. **Confirm the autoinstall (hands-on).** Open **VMConnect on PRAETORIAN**;
   subiquity pauses once for a "Continue with autoinstall? (yes|no)"
   confirmation (the seed ISO can't set the kernel cmdline) — type `yes`.
   The install runs unattended (~10–20 min) and reboots itself.
6. **Find the IP without KVP** (the minimal image has no `hv-kvp-daemon`, so
   `Get-VMNetworkAdapter().IPAddresses` is empty). Map the VM's MAC
   (`00:15:5D:00:18:1D`) to its LAN lease via an ARP/ping sweep of
   `192.168.1.0/24` from the control plane, or the router's DHCP table.
7. **SSH in** from the control plane (WSL2 → LAN → VM):
   `ssh -i infra/hyperv/cloud-init/.generated/rhl-acquired-cah/id_ed25519_rhl-acquired-cah ubuntu@<ip>`
   then `docker --version && docker compose version`.

## Validation (2026-06-13)

- [x] VM `Running`, reachable via SSH from the control plane over the LAN
      at **192.168.1.189** (MAC `00:15:5D:00:18:1D`, found via Host #2's
      neighbor cache — no KVP in the guest).
- [x] Docker 29.1.3 + Compose 2.40.3 present; Ubuntu 24.04.4 LTS, 4 vCPU,
      58 GB disk (50 GB free).
- [x] Host #2 RAM recorded: ~8 GB free before the VM; **6.6 GB free** with
      the VM running idle (VM assigned 1.23 GB / demand 0.75 GB). Gate H
      sizing (1/2/6 GB) holds; 3a.3 re-checks under OpenEMR load (ADR 0007).
- [x] Host #2's 6 pre-existing VMs remain Off / untouched.

SSH: `ssh -i infra/hyperv/cloud-init/.generated/rhl-acquired-cah/id_ed25519_rhl-acquired-cah ubuntu@192.168.1.189`

## Rollback

Over WinRM: `Stop-VM rhl-acquired-cah -TurnOff; Remove-VM rhl-acquired-cah -Force`,
then delete `C:\HyperV\rhl-acquired-cah`. Leaves the external vSwitch and
Host #2's other VMs intact.
