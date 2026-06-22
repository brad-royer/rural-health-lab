# Runbook: Participant Onboarding to the CIN HIE

How **any participant EHR** onboards to the CIN's HIE (HAPI hub) via
Mirth-mediated FHIR exchange. This is the generic template; **Bahmni (the
central hospital's EHR) is worked example #1** and **OpenEMR (the acquired
CAH's EHR) is worked example #2**. Two deliberately different EHRs — OpenMRS/
Java with basic-auth FHIR2 on one host, vs. LAMP/PHP with a SMART-OAuth FHIR
API across a second host — exercise the same flow. If a step below only makes
sense for one of them, that's a bug in this document.

Supersedes `docs/runbooks/phase-2-central-hospital-ehr.md`. The increment
runbooks are the deep-dive references: Phase 2 (`phase2-*`), Phase 3a
(`phase3a-*`).

## Invariants (bind every participant, every phase)

1. **HIE ≠ EHR.** No participant EHR gets privileged/direct access to the
   HIE's database — onboarding is Mirth-mediated FHIR exchange, full stop
   ("Topology Clarification", `docs/adr/0001-handoff.md`).
2. **Synthetic data only.** No real PHI, ever.
3. **One Mirth per organization** — federation (Known Lessons #9). The HIE's
   own org and each participant org each run one Mirth; none straddles orgs.
4. **Identifiers are participant-issued and disjoint.** Demographics may
   overlap (same humans at multiple facilities — reality); identifier systems
   never do. The HIE-side participant system URI is stamped by the Mirth
   transform, not assumed present in the source EHR (ADR 0003/0008).
5. **The HIE's resource ids are its own.** Channels upsert conditionally on
   identifier and never set/overwrite HIE ids; references resolve by
   identifier search, never hardcoded.

## Parameter sheet

Everything participant-specific lives here. Onboarding participant N = filling
a column, re-answering the gates, and (for a remote host) the networking step.

| Parameter | Bahmni — example #1 | OpenEMR — example #2 |
|---|---|---|
| Facility | Central hospital (CAH hub) | Acquired CAH |
| Host | Host #1 VM `rhl-central-hospital` (192.168.1.230) | Host #2 VM `rhl-acquired-cah` (192.168.1.189) |
| Same host as HIE? | Yes (co-located) | **No — cross-host** (see networking step) |
| EHR product | Bahmni Standard `emr` profile (OpenMRS) | OpenEMR 8.1.0 (LAMP) |
| EHR FHIR base | `…/openmrs/ws/fhir2/R4` | `…/apis/default/fhir` |
| EHR auth | Basic (`superman`/`Admin123`) | **SMART Backend Services OAuth** (client_credentials, private_key_jwt) |
| Patient identifier construct | OpenMRS type "Patient Identifier" (honored on create) | `pubpid` (FHIR create **ignores** supplied id → set via DB) |
| Patient system URI (HIE-side) | `https://lab.example/identifiers/bahmni-central` | `https://lab.example/identifiers/openemr-cah` |
| Encounter system URI (HIE-side) | `…/bahmni-central/encounter` | `…/openemr-cah/encounter` |
| Mirth instance | HIE's (Host #1, `compose/mirth/`) | CAH's own (Host #2, `compose/cah-mirth/`) |
| Channels | `compose/mirth/channels/bahmni-*` | `compose/cah-mirth/channels/openemr-*` |
| Encounter creation (for verify) | OpenMRS REST `/visit` | **DB insert** (FHIR Encounter read-only; std API 403 under machine auth) |
| Verify backend | `--ehr bahmni` | `--ehr openemr` |
| Polling / verify timeout | 60s / 180s | 60s / 300s |
| Seed panel | 15, `scripts/seed-panel-manifest.json` | 15, `scripts/openemr-seed-manifest.json` |
| Gate ADRs | 0004 (A), 0003 (B), 0005 (C) | 0007 (H), 0008 (I), 0006 (J), 0009 (K) |

## Decision gates (re-answer per participant, each an ADR)

- **Edition & sizing** (Bahmni: Gate A/ADR 0004; OpenEMR: Gate H/ADR 0007) —
  which edition, on what resources; measure, don't assume.
- **Panel identity** (Gate B/ADR 0003; Gate I/ADR 0008) — same humans as the
  HIE population, disjoint identifiers. Overlap is the realistic default and
  pre-stages MPI; OpenEMR deliberately overlapped Bahmni too (three-way).
- **Integration source & direction** (Gate C/ADR 0005; Gate K/ADR 0009) — how
  events leave the EHR (FHIR polling preferred), outbound first.
- **Cross-host networking** (new for remote participants: Gate J/ADR 0006) —
  only when the participant is on a different host than the HIE.

Every identity question these raise → `docs/phase3-parking-lot.md`, unsolved
(MPI is Phase 3b).

## Onboarding steps

### 1. Network the participant into the HIE (remote hosts only)

Skip if co-located (example #1, Bahmni on the HIE host). For a participant on
its own host (example #2), connect the two orgs with controlled, minimal
inter-org flows — *feel* the boundary, don't bulldoze it.

> **OpenEMR (#2):** `docs/runbooks/phase3a-cross-host-networking.md` —
> external vSwitch per host (wired NIC; Wi-Fi can't bridge), WinRM remote
> management of the participant host, and the HIE's HAPI exposed to the LAN
> via `netsh` portproxy + a subnet-scoped firewall rule (the single CAH→HIE
> flow). Gotchas: portproxy targets the volatile WSL IP; cable insertion
> moved the host IP.

### 2. Provision the participant host

A VM with Docker + Compose, SSH from the control plane, sized per the
edition/sizing gate, with before/after host resource usage recorded.

> **#1:** `phase2-vm-baseline.md` (Host #1). **#2:** `phase3a-vm-baseline.md`
> — same generalized `infra/hyperv/New-LabVM.ps1`, driven remotely over WinRM
> (ISO via BITS, files via `Copy-ToHost2.ps1`).

### 3. Deploy the EHR

Vendor container distribution, **pinning image versions you verified exist**
(packaging drift bit Bahmni, Mirth, and was re-checked for OpenEMR). Smoke
test: clinician logs in, registers a patient by hand. Record resource usage.

> **#1:** `phase2-bahmni-deployment.md`. **#2:** `phase3a-openemr-deployment.md`
> (`compose/openemr/`, OpenEMR 8.1.0). OpenEMR ships its REST/FHIR API
> **disabled** — enable the API globals first.

### 4. Seed the patient panel

Small, scripted, idempotent panel per the identity gate — committed manifest
with **script-assigned participant MRNs**, create-if-absent via the EHR API,
**no bulk synthetic import** (attempt once, capture the failure).

> **#1:** `phase2-seed-panel.md` (MRN honored on FHIR create). **#2:**
> `phase3a-seed-panel.md` — OpenEMR ignores supplied identifiers, so the
> seeder sets `pubpid` via DB keyed by the returned uuid; OAuth client must
> be registered + enabled first.

### 5. Wire into the HIE (Mirth channels)

Per resource type (Patient, then Encounter): **source** polls the EHR API;
**transform** strips EHR internals, normalizes to standard FHIR, and **stamps
the participant identifier system URI**; **sink** conditional-upserts into
HAPI keyed on identifier, encounters resolving subject by identifier (tolerate
arriving before their patient — engine retries may not cover script throws).
Channels committed as XML with fixed ids + a deploy script.

> **#1:** `phase2-mirth-channel.md` (HIE Mirth, basic-auth source). **#2:**
> `phase3a-cah-mirth.md` (CAH's own Mirth, A1) — source signs an RS384 JWT
> in-channel (`java.security`) for SMART OAuth; writes to HAPI **across the
> cross-host boundary**. Both: Apache HttpClient, not `java.net.URL` (Java 17).

**Authenticate to the HIE boundary (Phase 3b).** The participant gets a
Keycloak `client_credentials` client in the HIE realm; its Mirth channels
fetch a token (client secret mounted, gitignored) and present `Bearer` on
every HAPI call. The HIE write boundary is a **JWT-validating gateway** in
front of HAPI — so the sink target is the gateway, not HAPI directly, and
unauthenticated writes are rejected (401). The token issuer is pinned
(`KC_HOSTNAME`) so it's consistent whichever host requests it.

> Both: `phase3b-keycloak.md` (realm + per-participant clients) and
> `phase3b-hapi-oauth.md` (gateway, issuer, channel token-wiring). Gate N /
> ADR 0012.

### 6. Verify the onboarding

Run `scripts/verify-onboarding.py --ehr <participant>`: a same-human patient +
encounter round-trips to the HIE, correct identifier systems with nothing
internal leaked, existing HIE populations unchanged, and the duplicate-person
condition **called out as intentional**. The EHR-specific operations are a
**pluggable backend** (`scripts/ehr_backends.py`) — the per-participant seam.

> **#1/#2:** `phase2-verification.md` / `phase3a-verification.md`. Both PASS
> with only `--ehr` + env changes — the proof the template is generic.

## What onboarding example #2 taught about the template

- The verifier needed refactoring into **pluggable EHR backends** — the
  EHR-specific operations are a real seam, now isolated (a new EHR = a new
  backend class, not flow edits). This is the template earning the label.
- **Cross-host networking** had to be promoted from implicit (Phase 2,
  single host) to a first-class step — most real participants are remote.
- OpenEMR proved the EHR-API assumptions can't be taken for granted (OAuth,
  identifier handling, read-only/blocked encounter writes). The generic flow
  held; the seams absorbed the differences.

## Production delta (what this lab skips that production requires)

- **AuthN/AuthZ at the HIE boundary — implemented (Phase 3b).** Participants
  authenticate to the HIE with Keycloak `client_credentials` tokens, validated
  by a JWT-validating gateway in front of HAPI; unauthenticated writes are
  rejected (401). (Source-side EHR OAuth, e.g. OpenEMR's, was already real and
  internal to the participant.) Remaining hardening still delta:
  audience/scope-restricted tokens, mTLS, prod-mode Keycloak with TLS + secret
  rotation, and human IAL2/AAL2 flows (→ ID.me, Phase 5).
- **Transport/routing**: self-signed certs, trust-all in channels, and
  portproxy-over-WSL-NAT for the HIE endpoint are lab artifacts; production
  wants CA certs, a routable HIE address, and pfSense-style inter-org routing
  (Phase 4). Remote admin: HTTPS/Kerberos/JEA, not HTTP-WinRM + TrustedHosts.
- **Per-participant secret management**: the CAH Mirth holds the OAuth client
  private key as a mounted file; production wants a secrets manager.
- **BAAs / data-sharing agreements**; **audit logging & retention** (Mirth
  message store unpruned, HAPI unaudited).
- **Identifier-system registry & MPI — MPI implemented (Phase 3b).** Duplicate
  persons (now three-way) are reconciled by HAPI MDM (link-not-merge: golden
  records + `Patient.link`, demographics-matched), not just surfaced
  (`phase3b-hapi-mdm.md`, `phase3b-mdm-linkage.md` / Gate L / ADR 0010).
  Participant identifier-system URIs still live in channel transforms rather
  than a central registry — that registry remains delta.

## Related

- `docs/adr/0001-handoff.md`; ADRs 0003–0009 (the gates)
- `docs/phase2-kickoff-prompt.md`, `docs/phase3a-kickoff-prompt.md`
- `docs/phase3-parking-lot.md` — deferred identity/MPI questions
