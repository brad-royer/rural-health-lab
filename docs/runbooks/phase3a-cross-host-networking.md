# Runbook: Phase 3a.1 — Cross-Host Networking Baseline (Host #1 ↔ Host #2)

Establishes the controlled inter-organization boundary between the CIN/HIE
(Host #1) and the acquired CAH (Host #2), per Gate J
(`docs/adr/0006-...`, written in this increment) and the handoff's Hardware
Topology starter. First Phase 3a increment — nothing else can proceed until
Host #2 is reachable. Folds into `participant-onboarding.md` as the
(new) cross-host networking template step.

**Decisions (scoping, 2026-06-12):**
- **Service discovery: static IPs + hosts entries** (flat 192.168.1.0/24
  LAN, DHCP today; the OpenEMR VM gets a reserved/static address).
- **Remote management: WinRM first** — the control plane drives Host #2
  directly via `Invoke-Command`, so only the one-time bootstrap below needs
  hands on Host #2.

## Stage 0 — Remote-management bootstrap (one-time, your hands required)

The control plane (WSL2 on Host #1 "CENTURION") has no path to Host #2 (a
separate physical Area-51 R5) until WinRM is enabled. This is the only part
of 3a that must be run on Host #2 directly.

1. **On Host #2, elevated PowerShell** — enable WinRM, scoped to the LAN:

   ```powershell
   # copy the script over, or paste its contents
   .\Enable-RemoteMgmt-Host2.ps1
   ```
   Note the printed **Hostname** and **LAN IPv4**.

2. **On Host #1, elevated PowerShell** — trust Host #2 and save a credential
   the agent can use non-interactively:

   ```powershell
   .\Register-Host2-ControlPlane.ps1 -Host2 <Host2-IP-or-name>
   # prompts once for a Host #2 local-admin credential
   ```
   It adds Host #2 to TrustedHosts, saves the credential DPAPI-encrypted to
   `infra/hyperv/.secrets/host2-cred.xml` (gitignored — never committed,
   Hard Rule #6), and round-trips `Invoke-Command` to prove the path.

3. Report success + the Host #2 hostname/IP. The agent then drives the
   remaining stages over WinRM from the control plane.

**Why HTTP + TrustedHosts:** workgroup lab, no Active Directory, so WinRM
uses HTTP/5985 + NTLM with explicit credentials, which requires the client
to trust the host. The firewall rule is scoped to the LAN subnet.
**Production delta:** real cross-org admin uses HTTPS/5986 with a CA cert
and Kerberos/JEA constrained endpoints — not HTTP + TrustedHosts + a
broad local-admin credential.

## Stage 1 — vSwitch per host  _(done 2026-06-13, agent-driven over WinRM)_

External Hyper-V vSwitch on Host #2 (Host #1's already exists from Phase 2).
Driver: `infra/hyperv/Invoke-Host2.ps1` shipping
`infra/hyperv/remote/create-external-vswitch.ps1`.

```
rhl-lan-external  External  Killer E2500 Gigabit Ethernet Controller
host vEthernet (rhl-lan-external): 192.168.1.115/24
```

**Gotcha — Host #2 was Wi-Fi-only; external vSwitches don't bridge over
Wi-Fi.** PRAETORIAN's two Gigabit Ethernet ports were both unplugged; only
Wi-Fi (`192.168.1.200`) was up. A Hyper-V *external* switch needs a wired
NIC to bridge VMs onto the LAN, so a cable was connected to the "Ethernet"
port (it pulled `192.168.1.115`).

**Gotcha — connecting the cable moved the host's IP and dropped Wi-Fi**,
breaking the WinRM session (the management target `.200` went away while the
new wired link came up as `.115`). Resolution + the safe pattern:
- Run WinRM management over **Wi-Fi** while the external vSwitch is built on
  the **wired** NIC — the switch re-bind blips Ethernet, not the management
  path, so the session survives. (Building the switch on the same NIC you
  manage through will cut you off mid-`New-VMSwitch`.)
- Keep both links up (dual-homed on the LAN) for the duration; `192.168.1.*`
  is in the control plane's WinRM `TrustedHosts` so DHCP changes don't lock
  you out.
- Production delta: a server host would be on wired Ethernet with a reserved
  address from the start; the Wi-Fi-only starting point is a quirk of this
  particular box.

**Gotcha — Wi-Fi keeps dropping; wired `.115` is the management path.**
After the cable went in, PRAETORIAN's Wi-Fi (`.200`) repeatedly went down
(power management / deprioritized behind wired). Once the external vSwitch
existed on the wired NIC there was no further switch-blip risk, so the
control-plane drivers (`Invoke-Host2.ps1`, `Copy-ToHost2.ps1`) now default to
the wired **`192.168.1.115`**. Both `192.168.1.*` are in TrustedHosts, so
either works when up. A DHCP reservation for the wired NIC would make this
fully stable (deferred; `.115` has held across the session).

## Stage 2 — Addressing (done)

Current LAN addresses (DHCP; reservations deferred — see the WSL-IP gotcha):
- Host #1 (CENTURION): `192.168.1.176` (HIE host; HAPI exposed here).
- Host #2 (PRAETORIAN): `192.168.1.115` (wired, management path).
- OpenEMR VM (`rhl-acquired-cah`): `192.168.1.189`.
- Bahmni VM (`rhl-central-hospital`, Phase 2): `192.168.1.230`.

The agent targets these directly; no local DNS server (Gate J decision:
static IPs + known addresses).

## Stage 3 — Expose HIE HAPI + firewall (done 2026-06-14)

HAPI runs in WSL2 on Host #1 (NAT'd, localhost-only). For the CAH Mirth to
write to it (federation A1), `infra/hyperv/Expose-HAPI-ToLAN.ps1` (elevated on
Host #1) adds a `netsh` portproxy (host LAN `:8080` → WSL2 HAPI) and a
firewall rule allowing inbound `8080` **only from `192.168.1.0/24`** — the
single controlled CAH→HIE flow. Admin paths (WinRM Host #1→Host #2; SSH
control plane→VMs) are the only other inter-host flows.

**Gotcha — portproxy targets the volatile WSL IP.** The WSL2 address
(`172.27.x`) changes on WSL restart; re-run `Expose-HAPI-ToLAN.ps1` after a
Host #1 reboot/WSL restart. Production delta: a real HIE FHIR endpoint has a
routable address (no portproxy-over-NAT).

## Validation (2026-06-14)

- [x] Control plane reaches Host #2 over WinRM (`Invoke-Host2.ps1`).
- [x] Allowed flow works: from the CAH VM,
      `curl http://192.168.1.176:8080/fhir/metadata` → 200; the CAH Mirth
      synced 15 patients into HAPI across the boundary.
- [x] HAPI is not otherwise LAN-reachable (only the scoped `:8080` rule +
      WSL portproxy expose it; default WSL services aren't LAN-visible).

## Rollback

```powershell
# On Host #1 (elevated): remove the HAPI exposure
netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=8080
Remove-NetFirewallRule -DisplayName rhl-hie-hapi-8080
# Remove WinRM trust (optional): Set-Item WSMan:\localhost\Client\TrustedHosts -Value '' -Force
```
```powershell
# On Host #2 (elevated): remove the external vSwitch
Remove-VMSwitch -Name rhl-lan-external -Force
```
