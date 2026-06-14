# ADR 0006 - Gate J: Cross-Host Networking and Service Discovery

## Status
Accepted - 2026-06-14

## Context
Phase 3a (`docs/phase3a-kickoff-prompt.md`, Gate J) puts the acquired CAH on
a second physical host (Host #2, PRAETORIAN) and must connect it to the HIE
on Host #1 (CENTURION) so the CAH's Mirth can write to HAPI (federation A1).
The handoff (`docs/adr/0001-handoff.md`, Hardware Topology) sets the starter:
same LAN, an external vSwitch per host, local service discovery, and host
firewall rules controlling inter-org traffic - with pfSense/OPNsense as the
Phase 4 upgrade. Gate J fixes the specifics, measured against what the boxes
actually allow.

## Decision
1. **Same LAN, external vSwitch per host.** Both hosts on `192.168.1.0/24`;
   Host #2 gets a Hyper-V external vSwitch (`rhl-lan-external`) on its wired
   NIC so the OpenEMR VM pulls a real LAN lease (mirrors Host #1).
2. **Service discovery: static addressing + known IPs/hosts entries** (no
   local DNS server) - the flat-LAN pragmatic choice.
3. **Remote management of Host #2 over WinRM** (no AD): HTTP/5985 + NTLM with
   an explicit admin credential (DPAPI-encrypted, gitignored) and the host in
   the control plane's TrustedHosts. Lets the control plane drive Host #2's
   Hyper-V/Docker without per-step hands-on.
4. **HIE HAPI exposed to the LAN via `netsh` portproxy + a scoped firewall
   rule** (`Expose-HAPI-ToLAN.ps1`). HAPI runs in WSL2 on Host #1 (NAT'd,
   localhost-only); the portproxy forwards Host #1's LAN `:8080` to WSL2's
   HAPI, and the firewall rule allows inbound `8080` **only from
   `192.168.1.0/24`** - the single controlled cross-org flow (CAH Mirth ->
   HIE HAPI). Plus admin paths: WinRM (Host #1 -> Host #2), SSH (control
   plane -> the VMs).
5. **pfSense/OPNsense deferred to Phase 4** (handoff) - the per-host
   vSwitch + firewall-rule starter is Phase 3a.

## Measured gotchas (the cross-host lesson, not incidental plumbing)
- **External vSwitch can't bridge over Wi-Fi.** PRAETORIAN's Ethernet ports
  were unplugged; a wired NIC was required for the external switch.
- **Connecting the cable moved the host IP and dropped Wi-Fi**, breaking the
  WinRM session mid-setup. Safe pattern: manage over one link while switching
  the other; keep `192.168.1.*` in TrustedHosts so DHCP changes don't lock
  you out. Wi-Fi proved flaky, so the wired `.115` became the management path.
- **HAPI behind WSL2 NAT** is the awkward part: portproxy targets the WSL IP,
  which **changes on WSL restart** - re-run `Expose-HAPI-ToLAN.ps1` after a
  reboot. A real HIE FHIR endpoint would just have a routable address.

## Consequences
- The controlled flow is demonstrable both ways: CAH VM -> `192.168.1.176:8080/fhir`
  works (200); HAPI is not otherwise LAN-reachable.
- Operational fragility (WSL IP volatility, Wi-Fi drops) is documented in
  `docs/runbooks/phase3a-cross-host-networking.md`; these are lab artifacts,
  not the target architecture.
- Production deltas (Phase 4+ / Phase 3b): pfSense inter-org boundary;
  HTTPS/Kerberos/JEA for remote admin instead of HTTP-WinRM + TrustedHosts;
  a routable HIE address instead of portproxy-over-WSL; OAuth/mTLS on the
  HAPI write (Keycloak, 3b) instead of the subnet-scoped firewall allow.

## Related
- `docs/adr/0001-handoff.md` - Hardware Topology starter
- ADR 0009 (Gate K) - the federation flow this boundary carries
- `docs/runbooks/phase3a-cross-host-networking.md`
- `infra/hyperv/Expose-HAPI-ToLAN.ps1`, `Enable-RemoteMgmt-Host2.ps1`,
  `Register-Host2-ControlPlane.ps1`; issue #27
