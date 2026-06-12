# Runbook: Participant Onboarding to the CIN HIE

How **any participant EHR** onboards to the CIN's HIE (HAPI hub) via
Mirth-mediated FHIR exchange. This is the generic template (Phase 2's
primary deliverable, issue #15); **Bahmni — the central hospital's EHR —
is worked example #1**, and the `OpenEMR` column/blanks are for Phase 3's
acquired-CAH onboarding to fill in. If a step below only makes sense for
Bahmni, that's a bug in this document.

Supersedes `docs/runbooks/phase-2-central-hospital-ehr.md` (now a pointer).
The increment-specific runbooks remain the deep-dive references:
`phase2-vm-baseline.md`, `phase2-bahmni-deployment.md`,
`phase2-seed-panel.md`, `phase2-mirth-channel.md`, `phase2-verification.md`.

## Invariants (bind every participant, every phase)

1. **HIE ≠ EHR.** The HIE is the aggregation/exchange layer. No
   participant EHR ever gets privileged or direct access to the HIE's
   database — onboarding is Mirth-mediated FHIR exchange, full stop
   ("Topology Clarification", `docs/adr/0001-handoff.md`).
2. **Synthetic data only.** No real PHI, ever, and no design that only
   works for real PHI.
3. **One Mirth** until the Phase 3 federation pattern deliberately adds a
   second (Hard Rule #3).
4. **Identifiers are participant-issued and disjoint.** Demographics may
   overlap (same humans exist at multiple facilities — that's reality);
   identifier systems never do. The HIE-side system URI is stamped by the
   Mirth transform, not assumed to exist in the source EHR (ADR 0003 and
   its dated update).
5. **The HIE's resource ids are its own.** Channels upsert conditionally
   on identifier and never set or overwrite HIE resource ids; references
   are resolved by identifier search, never hardcoded.

## Parameter sheet

Everything participant-specific lives here. Onboarding participant N =
filling in a new column and re-answering the three decision gates.

| Parameter | Bahmni (worked example #1) | OpenEMR (Phase 3 — fill in) |
|---|---|---|
| Participant / facility | Central hospital (CAH hub) | Acquired CAH |
| Host | Host #1 Hyper-V VM `rhl-central-hospital` (192.168.1.230) | Host #2 (idle until Phase 3) |
| EHR product / version | Bahmni Standard, `emr` profile (Docker tags pinned per 2.2 runbook) | _TBD_ |
| EHR FHIR API base | `https://192.168.1.230/openmrs/ws/fhir2/R4` | _TBD_ |
| EHR native API base (the non-FHIR seam) | `https://192.168.1.230/openmrs/ws/rest/v1` | _TBD_ |
| EHR auth | Basic, `superman`/`Admin123` (lab default) | _TBD_ |
| Primary identifier construct | OpenMRS identifier type `Patient Identifier` | _TBD_ |
| Patient identifier system URI (HIE-side) | `https://lab.example/identifiers/bahmni-central` | _TBD — mint a new URI_ |
| Encounter identifier system URI (HIE-side) | `https://lab.example/identifiers/bahmni-central/encounter` | _TBD — mint a new URI_ |
| Mirth channels (fixed ids, committed XML) | `compose/mirth/channels/bahmni-{patient,encounter}-to-hie.xml` | _TBD — new files, new ids_ |
| Polling interval / verify timeout | 60s / 180s | _TBD_ |
| Seed panel | 15 patients, `scripts/seed-panel-manifest.json` | _TBD_ |
| Gate ADRs | 0004 (A), 0003 (B), 0005 (C) | _TBD — three new ADRs_ |

## Decision gates (re-answer per participant, each as an ADR)

- **Gate A — edition & sizing.** Which edition/profile of the EHR, on what
  resources? Measure, don't assume: provision the host first, record
  before/after usage, set a fallback ladder and a re-evaluation checkpoint
  (worked example: ADR 0004 — Bahmni Standard via Dynamic Memory 2/4/16 GB,
  checkpoint passed at ~5 GB demand).
- **Gate B — panel identity strategy.** Are the participant's patients the
  same humans as existing HIE patients (overlapping demographics, disjoint
  identifiers) or a disjoint population? Overlap is the realistic default
  and pre-stages the MPI/dedup lesson (worked example: ADR 0003). Every
  identity question this raises goes to `docs/phase3-parking-lot.md`,
  unsolved (Hard Rule #5).
- **Gate C — integration source & direction.** How do events leave the
  EHR (FHIR API polling vs. native feeds vs. HL7v2), and which directions
  are in scope? Outbound (EHR -> HIE) first; keep the participant passive
  if possible (worked example: ADR 0005 — poll OpenMRS FHIR2 R4,
  outbound-only; atom feeds and HL7v2 rejected with reasons).

## Onboarding steps

### 1. Provision the participant host

Generic: a VM with Docker + Compose, SSH from the control plane, sized per
Gate A, with before/after host resource usage recorded (capacity-planning
input for the next participant). Don't deploy on a host reserved for a
later phase.

> **Worked example #1:** `docs/runbooks/phase2-vm-baseline.md` —
> Hyper-V Gen2 via checked-in PowerShell + cloud-init autoinstall, with
> the measured Host #1 numbers and 5 provisioning gotchas (local-disk ISO
> for `Add-VMDvdDrive`, subiquity confirm prompt, missing KVP daemon,
> UNC-path SSH key perms, Gen2 firmware RAM reservation).

### 2. Deploy the EHR

Generic: deploy via the vendor's container distribution, **pinning image
versions you verified exist** — check the registry, not your memory or
the vendor's checked-in defaults (packaging drift bit twice: Bahmni's
stale `.env` tags in 2.2, Mirth's open-source line ending at 4.5.2 in
2.4). Smoke test: a clinician can log in and register a patient by hand.
Record idle and light-use resource numbers against the Gate A checkpoint.

> **Worked example #1:** `docs/runbooks/phase2-bahmni-deployment.md` —
> Bahmni Standard `emr` profile (11 containers), `.env.local` tag fixes,
> resource table, ADR 0004 checkpoint PASS.

### 3. Seed the patient panel

Generic: a small, scripted, idempotent, re-runnable panel per Gate B — a
committed manifest pinning demographics + **script-assigned participant
MRNs** (fixed MRNs are what make re-runs idempotent), a seeder that
creates-if-absent via the EHR's FHIR API, and **no bulk synthetic-data
import** (attempt it once, capture exactly how it fails, document why).
No HIE/source-population identifier ever enters the participant EHR.

> **Worked example #1:** `docs/runbooks/phase2-seed-panel.md` —
> 15-patient manifest, `scripts/seed-bahmni-panel.py`, the measured
> bulk-import failure modes (no transaction endpoint; preferred-identifier
> rejection), and the FHIR2 `Address.line` create-drop + REST repair.

### 4. Wire into the HIE (Mirth channels)

Generic, per resource type (start with Patient, then Encounter):

- **Source**: poll the EHR's API per Gate C (incremental via
  `_lastUpdated` or equivalent; full resync on redeploy must be safe).
- **Transform**: emit a minimal HIE resource — strip every EHR-internal
  id/extension, normalize proprietary representations to standard FHIR,
  and **stamp the participant's identifier system URI** (the type->URI
  mapping lives here, in the integration layer).
- **Sink**: conditional upsert keyed on
  `identifier=<participant system>|<value>`. Encounters resolve subjects
  by identifier search against the HIE — and must tolerate arriving
  before their patient (in-channel wait; engine-level retries may not
  cover script exceptions — measured 2.5 lesson).
- Channels live in the repo as XML with fixed ids;
  `scripts/deploy-mirth-channels.sh` imports + deploys idempotently.

> **Worked example #1:** `docs/runbooks/phase2-mirth-channel.md` —
> channel design, the Java 17/Rhino HttpClient constraint, 6 gotchas,
> rollback. ADR 0005 records the Gate C reasoning.

### 5. Verify the onboarding

Generic: run `scripts/verify-onboarding.py` with the participant's
parameter-sheet values as env vars (table in
`docs/runbooks/phase2-verification.md`). It must PASS repeatably:
patient + encounter round trip within the timeout, correct identifier
systems with nothing internal leaked, existing HIE populations unchanged,
and the duplicate-person condition **called out as intentional** — record
linkage is the deferred Phase 3 lesson, not something to fix here. The
EHR-native calls (seed-panel address repair, visit creation) are the
expected per-participant seam in the script.

> **Worked example #1:** `docs/runbooks/phase2-verification.md` — three
> consecutive PASS transcripts, plus the two bugs verification caught
> (terminal encounter-before-patient race; HAPI's ~60s search cache vs.
> count assertions).

## Production delta (what this lab skips that production requires)

- **AuthN/AuthZ between participants and the HIE**: real deployments use
  OAuth 2.0 (SMART backend services / client credentials) or mTLS per
  participant; this lab uses basic auth with vendor-default credentials
  hardcoded in channel XML. Keycloak arrives in Phase 3 to model this.
- **Transport security**: lab traffic crosses a private LAN with
  self-signed certs and trust-all TLS in the channels; production
  requires CA-issued certs, hostname verification, and no plaintext HTTP
  (the HIE listens on plain 8080 here).
- **BAAs and data-sharing agreements** before any PHI flows; this lab
  models the concept only (synthetic data, no agreements).
- **Audit logging & retention**: who queried/wrote what, when, tamper
  evident, with a retention policy. Mirth's message store is PRODUCTION
  mode here but unpruned and unaudited; the HIE has no access logging.
- **Identifier-system registry**: a governed registry of participant
  identifier system URIs (and a no-reuse policy for retired MRNs) instead
  of URIs living only in channel transforms
  (`docs/phase3-parking-lot.md` #2, #3).
- **MPI/record linkage**: production HIEs reconcile duplicate persons;
  this lab intentionally surfaces duplicates and defers linkage
  (`docs/phase3-parking-lot.md` #1).
- **Resilience**: Mirth on embedded Derby with a single instance and no
  HA; production wants Postgres-backed Mirth, monitoring, and alerting on
  channel errors (a terminally ERROR'd message here is found by reading
  stats, not by a page).

## Related

- `docs/adr/0001-handoff.md` — Lab Narrative, Topology Clarification,
  Known Lessons (esp. #5, #6, #7), Hardware Topology
- ADR 0003 (Gate B), ADR 0004 (Gate A), ADR 0005 (Gate C)
- `docs/phase2-kickoff-prompt.md` — Phase 2 scope + Definition of Done
- `docs/phase3-parking-lot.md` — deferred identity questions
