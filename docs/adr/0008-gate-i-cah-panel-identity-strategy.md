# ADR 0008 - Gate I: Acquired-CAH (OpenEMR) Panel Identity Strategy

## Status
Accepted - 2026-06-13

## Context
Phase 3a (`docs/phase3a-kickoff-prompt.md`, Gate I) seeds the acquired CAH's
OpenEMR with a small hand-managed panel. Gate I is the OpenEMR analog of
Gate B (ADR 0003, the Bahmni panel): same humans as the HIE's Synthea
population, or disjoint? And, new for Phase 3: how does it relate to the
Bahmni panel already onboarded?

## Decision
The OpenEMR seed panel reuses **demographics** (name, DOB, gender, address)
from a subset of the Synthea rural-TX population - the *same humans* - with
identifiers **fully disjoint** under a new CAH-specific FHIR identifier
system URI `https://lab.example/identifiers/openemr-cah` (MRNs `CAH-0001`..
`CAH-0015`). No Synthea/HAPI/Bahmni identifier is copied into OpenEMR. This
mirrors ADR 0003.

**New: deliberate three-way overlap.** Five of the fifteen OpenEMR patients
(`CAH-0001`..`CAH-0005`) are the *same Synthea humans* as Bahmni's
`BAH-0001`..`BAH-0005`. So after 3a.5 (CAH -> HIE) those five people will
exist **three times** in the HIE - the Synthea original, the Bahmni-sourced
copy, and the OpenEMR-sourced copy - under three disjoint identifier
systems. The other ten (`CAH-0006`..`CAH-0015`) are distinct Synthea humans
not in the Bahmni panel (two-way: Synthea + OpenEMR). The panel is pinned in
`scripts/openemr-seed-manifest.json`.

This is a human decision (the builder), recorded as Accepted.

## Rationale
- **Maximizes the Phase 3b MPI/record-linkage lesson.** A person existing in
  three systems under three identifier systems, with demographics that don't
  round-trip faithfully (the lossiness recorded in
  `docs/phase3-parking-lot.md` #1), is the hardest, most realistic
  record-linkage case - exactly what 3b's MDM work should be handed, and
  more demanding than Bahmni's two-way duplication alone.
- **Realistic.** In an acquisition, the acquired facility's patients very
  often already exist in the acquirer's HIE *and* in the central hospital's
  EHR (shared regional population). Full disjointness would understate the
  problem.
- **Keeps 3a cleanly scoped.** As with ADR 0003, the CAH Mirth's conditional
  upsert only ever targets the `openemr-cah` system; no cross-system
  identifier resolution is needed to close 3a. The duplication is created,
  not resolved (Hard Rule #7 - MPI is 3b).

## Consequences
- 3a.4 registers `CAH-0001`..`CAH-0015` in OpenEMR via its FHIR API under the
  `openemr-cah` system (idempotent seeder, like 2.3's).
- After 3a.5, the HIE intentionally holds three-way duplicates for five
  humans and two-way for ten. The 3a.6 verification must call this out as an
  intentional artifact, and `docs/phase3-parking-lot.md` updated with the
  three-way linkage questions (still not acted on).
- The identifier-system registry question (parking-lot #2) gains a third
  participant URI - reinforcing that a governed registry is Phase 3b work.

## Related
- ADR 0003 (Gate B) - the Bahmni panel analog this mirrors and overlaps
- `docs/phase3a-kickoff-prompt.md` - Gate I
- `scripts/openemr-seed-manifest.json` - the pinned panel + overlap map
- `docs/phase3-parking-lot.md` - deferred MPI questions
- Increment 3a.4 (#30)
