# Phase 2 Kickoff — Onboard the Central Hospital EHR (Bahmni) to the CIN HIE

You are starting Phase 2 of the rural health tech lab. Phase 1 (HAPI HIE core,
Synthea population, minimal Mirth) is complete and tagged `v0.1.0-phase1`.

## Step 0 — Inventory before planning (do this first, change nothing)

Read `CLAUDE.md`, `/docs` (handoff, ADRs, runbooks), and the repo itself.
Produce a short written summary of what Phase 1 *actually* deployed: VMs,
compose files, Mirth channels, HAPI data volume, ports, current resource
usage on Host #1. Do not assume the handoff describes reality — verify.

## Step 1 — Plan before executing

Per working agreements, propose a written Phase 2 plan and a GitHub issue
breakdown (one issue per increment below, under a Phase 2 milestone/epic)
and wait for approval before any infrastructure change. Every increment
ships as a PR. Every completed increment updates its issue.

## Mission

Onboard the central hospital's own EHR (Bahmni) onto the CIN HIE (HAPI FHIR)
**as a participant**, via the existing Mirth instance — and produce the
**Participant Onboarding Runbook** that Phase 3 will reuse verbatim-ish for
the acquired CAH's OpenEMR.

The runbook is the primary deliverable. The working integration is the
evidence that the runbook is correct.

## Hard rules — violating any of these means STOP and ask the human

1. **HAPI is the HIE, not the hospital's EHR.** Bahmni exchanges with HAPI
   only through Mirth-mediated FHIR. No direct writes to HAPI's database, no
   pointing Bahmni modules at HAPI directly, no privileged shortcuts — even
   if it would be faster or "cleaner." This is the central anti-pattern the
   lab exists to avoid (handoff: Topology Clarification).
2. **Do not load Synthea into Bahmni.** Bahmni gets a small hand-managed
   panel (~10–20 patients, scripted seeding is fine, bulk import is not).
   The mismatch between HAPI's full population and Bahmni's small panel is
   intentional and is itself the learning surface (Known Lessons #6). Do not
   "fix" it.
3. **One Mirth.** Use the existing CIN Mirth instance. A second Mirth is
   Phase 3's federation lesson — standing it up early destroys that lesson.
4. **Host #2 stays idle.** Everything in Phase 2 runs on Host #1 (Known
   Lessons #8).
5. **No MPI/dedup/record-linkage work.** When duplicate-patient questions
   surface (they will), record them in `/docs/phase3-parking-lot.md` and
   move on (Known Lessons #5).
6. **No Terraform/Ansible.** IaC is Phase 4. VM provisioning in Phase 2 is
   PowerShell scripts plus runbook steps; services are Docker Compose.
7. **Synthetic data only.** No real PHI, ever.

## Non-goals (do not reintroduce these, even as improvements)

Medplum portal (deferred, ADR 0002) · Keycloak / any auth hardening ·
FHIR Subscriptions · second Mirth instance · Host #2 · cross-host networking ·
Terraform/Ansible/Packer · MPI/EMPI tooling.

## Decision gates — resolve early, each produces an ADR in /docs/adr/

**Gate A — Bahmni edition and sizing.** Check current Bahmni documentation
(packaging changes; do not rely on memory) and confirm Host #1 can give the
new EHR VM ≥16 GB RAM / 4 vCPUs alongside the running Phase 1 stack.
Fallback ladder, in order: Bahmni Standard → Bahmni Lite → vanilla OpenMRS
(Known Lessons #7). Whatever lands, document the constraint explicitly —
do not silently undersize and fight performance.

**Gate B — Panel identity strategy.** Recommend whether Bahmni's seed panel
reuses demographics from the Synthea population already in HAPI (same
humans, disjoint identifiers — pre-stages the Phase 3 dedup lesson) or is
fully disjoint. Default recommendation: overlapping demographics, disjoint
identifiers. Justify and write the ADR; do NOT act on the dedup implications.

**Gate C — Integration source and direction.** Investigate how to get
patient/encounter events out of Bahmni: OpenMRS FHIR2 (R4) API polling vs.
Bahmni's atom feeds vs. anything HL7v2-shaped. Recommend one with tradeoffs.
Scope: **outbound (Bahmni → Mirth → HAPI) is required; inbound (Bahmni-side
query of HIE data) is a stretch goal.** Bidirectional sync is not required
to close Phase 2.

## Work breakdown (refine in your plan; each is an issue + PR)

- **2.1 — Central-hospital VM baseline.** Hyper-V VM on Host #1
  (PowerShell script, checked in), Docker + Compose installed, documented in
  a runbook. Record before/after host resource usage.
- **2.2 — Bahmni deployment** (per Gate A) via its Docker Compose
  distribution. Smoke test: clinician can log in, register a patient by
  hand. Record actual RAM/CPU under idle and light use.
- **2.3 — Seed the patient panel** (per Gate B). Small, scripted,
  re-runnable, idempotent.
- **2.4 — Mirth channel(s)** (per Gate C): source connector from Bahmni,
  transform, then **conditional create/update into HAPI keyed on
  `Patient.identifier`** with a Bahmni-specific identifier system URI
  (e.g. `https://lab.example/identifiers/bahmni-central`). Never set or
  overwrite HAPI resource IDs. Encounters reference patients by identifier
  resolution, not hardcoded IDs.
- **2.5 — Verification script.** A written, repeatable test: register a new
  patient + encounter in Bahmni → assert it appears in HAPI within N minutes
  with correct identifiers → assert HAPI's Synthea population count is
  unchanged. This doubles as the Phase 3 acceptance test template.
- **2.6 — Participant Onboarding Runbook**
  (`/docs/runbooks/participant-onboarding.md`). Written as a **generic,
  parameterized template** — "how any participant EHR onboards to the CIN
  HIE" — with Bahmni filled in as worked example #1 and blanks Phase 3 will
  fill for OpenEMR. Draft the skeleton before executing 2.4, refine as you
  go. If it reads as a Bahmni install guide, it has failed its purpose.
  Include a **"production delta"** section: what this lab skips that
  production requires (OAuth between participants and HIE — arrives with
  Keycloak in Phase 3; BAAs; audit logging; transport security).

## Working agreements (restated; they bind you)

PR-based workflow even though solo. Propose plans before destructive or
infra-changing operations. Every automated step has a documented manual
path in `/docs/runbooks/`. Every completed task updates its GitHub issue.

## Definition of done

- A patient registered in Bahmni appears in HAPI via Mirth, demonstrated by
  the 2.5 verification script and captured in the runbook.
- Participant Onboarding Runbook merged, parameterized for Phase 3 reuse.
- ADRs for Gates A, B, C merged.
- Host #1 resource usage recorded (input to Phase 3 capacity planning).
- Phase 3 parking lot exists and captures every deferred identity question.
- Tag `v0.2.0-phase2`.
