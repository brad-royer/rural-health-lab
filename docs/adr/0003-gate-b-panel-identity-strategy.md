# ADR 0003 — Gate B: Bahmni Seed Panel Identity Strategy

## Status
Accepted — 2026-06-12

## Context
Phase 2 (`docs/phase2-kickoff-prompt.md`, Gate B) onboards Bahmni as the
central hospital's EHR. Per Known Lessons #6 (`docs/adr/0001-handoff.md`),
Bahmni gets a small (~10-20 patient) hand-managed seed panel — the full
Synthea population stays in HAPI only. Gate B asks: should that seed
panel's patients be the *same humans* as a subset of HAPI's Synthea
population (overlapping demographics), or a fully disjoint set of humans?

## Decision
Bahmni's seed panel (increment 2.3) reuses demographics — names, dates of
birth, addresses, gender — from a subset of the Synthea rural-TX
population already loaded in HAPI. These are the *same humans*.

Identifiers are fully disjoint: Bahmni assigns its own MRNs under a
Bahmni-specific FHIR identifier system URI (e.g.
`https://lab.example/identifiers/bahmni-central`). No identifier system or
value from the HAPI/Synthea population is copied into Bahmni.

This is a human decision (the builder), recorded here as Accepted and not
open for re-recommendation.

## Rationale
- **Pre-stages the Phase 3 MPI/EMPI dedup lesson** (Known Lessons #5).
  After increment 2.4 (Mirth: Bahmni -> HAPI), HAPI will hold *two* Patient
  resources for some real people: the original Synthea-seeded resource,
  and a new one created via Mirth's conditional create/update keyed on the
  Bahmni identifier system. This visible duplication is the exact shape of
  a real-world record-linkage problem, surfaced without building any
  dedup tooling now.
- **Keeps 2.4 cleanly scoped.** Mirth's conditional create/update only ever
  targets the Bahmni identifier system — it never needs to search,
  resolve, or merge against the Synthea/HAPI identifier system. No
  cross-system identifier resolution logic is required to close Phase 2.
- **Realistic.** In the acquisition scenario this lab models, the
  onboarded facility's patients usually *do* already exist somewhere in
  the acquirer's HIE under different identifiers — fully disjoint
  demographics would understate the integration problem.

## Consequences
- Increment 2.3 selects ~10-20 patients from `synthea/output/fhir/*.json`,
  reuses their demographics, and registers them in Bahmni with new
  Bahmni-issued MRNs under the identifier system above.
- After increment 2.4, HAPI intentionally contains duplicate-person
  records (same human, two Patient resources, disjoint identifier
  systems). This must be called out explicitly in the 2.5 verification
  script's output and in the participant onboarding runbook (2.6) as an
  intentional artifact, not a bug.
- Any MPI/dedup/record-linkage questions this raises are recorded in
  `/docs/phase3-parking-lot.md` and are explicitly **not** acted on in
  Phase 2 (Hard Rule #5).

## Related
- Known Lessons #5, #6 — `docs/adr/0001-handoff.md`
- `/docs/phase3-parking-lot.md`
- `docs/phase2-kickoff-prompt.md` — Gate B

## Update — 2026-06-12: where the identifier system URI lives (2.3 finding)

Implementing increment 2.3 surfaced an implementation detail this ADR's
wording glossed over: OpenMRS does not store FHIR `identifier.system`
URIs at all. Bahmni identifies identifiers by local *type* — the seed
MRNs (`BAH-0001`..`BAH-0015`) live under Bahmni's required "Patient
Identifier" type, and Bahmni's FHIR R4 output carries only that type and
the value, with no `system` element (verified against
`bahmni/openmrs:1.1.3`).

The decision stands unchanged — identifiers are fully disjoint and
Bahmni-issued — but the system URI
`https://lab.example/identifiers/bahmni-central` is **attached by the
Mirth transform in increment 2.4** (mapping identifier type → system
URI), not stored in Bahmni. Consequence for 2.4: the transform owns the
type→URI mapping, and 2.5's verification asserts the URI on the
HAPI side, not the Bahmni side. The registry-of-identifier-systems
question this raises is parked (entry #2 in
`/docs/phase3-parking-lot.md`).
