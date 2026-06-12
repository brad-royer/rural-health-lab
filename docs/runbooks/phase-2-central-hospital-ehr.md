# Runbook: Phase 2 — Central Hospital EHR (Bahmni)

**Status: stub.** This runbook is created during Phase 2 architecture
planning, ahead of implementation. Sections below are placeholders to be
filled in as the corresponding Phase 2 issues land. See
`docs/adr/0001-handoff.md` ("Lab Narrative", "Topology Clarification",
"Open-Source Stack Selected", "Roadmap Phases") for the decisions this
runbook implements.

## Goal

Stand up Bahmni (OpenMRS + OpenERP + OpenELIS) as the central hospital's own
EHR on Host #1, and onboard it to the CIN HIE (HAPI) as a participant —
Mirth-mediated FHIR exchange, not privileged/direct access to HAPI's
database (per "Topology Clarification" — HIE ≠ EHR).

This runbook is written to be reusable as the template for Phase 3's
acquired-CAH (OpenEMR) onboarding.

## Prerequisites

- Phase 1 complete (tagged `v0.1.0-phase1`): Postgres-backed HAPI hub + 2
  spokes + Synthea population, reproducible from a clean state.
- Host #1 RAM/CPU budget verified: Bahmni needs ~16 GB RAM and 4 vCPUs in
  addition to the existing Phase 1 stack (~36 GB total lab footprint on
  Host #1's 64 GB). See "Hardware Topology" in `docs/adr/0001-handoff.md`.
- **Fallback decision point:** if Host #1 cannot allocate ≥16 GB RAM and 4
  vCPUs to the central hospital VM, fall back to vanilla OpenMRS instead of
  full Bahmni, and document that constraint explicitly in this runbook
  (Known Lessons item 7 in `docs/adr/0001-handoff.md`).
- Host #2 remains idle for this phase — nothing in this runbook should
  require Host #2.

## Manual deployment path

_Placeholder — to be filled in when the Bahmni compose/deployment work
lands (tracked issue: "Phase 2: Stand up Bahmni central hospital EHR on
Host #1")._

## Automation path

_Placeholder — to be filled in alongside the manual path. Per repo
convention, automation and its manual fallback are documented together._

## Validation checks

_Placeholder — to be filled in alongside "Validate FHIR exchange end-to-end
(Bahmni → Mirth → HAPI)". Expect checks similar to Phase 1's: service
reachability, a round-trip resource create/read, and confirmation that
Bahmni-originated data appears in HAPI via Mirth._

## Rollback procedure

_Placeholder — to be filled in alongside the deployment steps. Should cover
tearing down the Bahmni stack without affecting the Phase 1 HAPI
hub/spokes/Postgres volume._

## Fallback: vanilla OpenMRS

If the Host #1 RAM/CPU check in "Prerequisites" fails, substitute vanilla
OpenMRS for full Bahmni:

- Same role in the topology (central hospital's own EHR, onboarded to the
  HIE via Mirth like any other participant).
- Lower resource footprint than Bahmni (no OpenERP/OpenELIS components).
- Document which components were dropped and why, so Phase 3's OpenEMR
  onboarding (which reuses this runbook as a template) accounts for the
  difference if Host #2 has its own constraints.
