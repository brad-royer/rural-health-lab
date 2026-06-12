# ADR 0002 — Defer Medplum out of Phase 1

## Status
Accepted — 2026-06-11

## Context
ADR 0001 (the handoff) placed Medplum in Phase 1 as the patient-facing portal for
the HAPI hub. Building Phase 1 surfaced two problems:
- Medplum is not a thin front-end for an existing FHIR server. It is a complete
  FHIR-native platform — its own FHIR server, Postgres, Redis, and app UI — that
  owns its datastore and renders its own data, not HAPI's. Showing the hub's
  Synthea population in Medplum would require replicating HAPI → Medplum, which is
  Phase 2 HIE-plumbing work, not Phase 1 local-core work.
- A patient portal's core value is identity-verified access (IAL2/AAL2), which
  depends on Keycloak, a Phase 2 component. A no-auth portal in Phase 1 is
  incomplete by design.

## Decision
Remove Medplum from Phase 1. Phase 1's "view the data" need is met by HAPI's built-in
tester UI at http://localhost:8080/. The patient portal is deferred to Phase 2+,
to be built once Keycloak provides identity.

## Consequences
- Phase 1 delivers a complete local core: Postgres-backed HAPI hub + 2 H2 spokes +
  loaded rural-TX Synthea population + HAPI's browsable UI.
- Two Medplum options are parked for later (choice deferred):
  1. Medplum as an onboarded partner node — run Medplum as its own FHIR platform and
     integrate it into the HIE the way a real partner EMR is onboarded (via Mirth /
     FHIR exchange). Its being a full platform is an asset here, not a liability.
  2. Medplum as the base FHIR server of a separate lab — a distinct learning track.
- The Medplum line in ADR 0001 is superseded by this ADR.
