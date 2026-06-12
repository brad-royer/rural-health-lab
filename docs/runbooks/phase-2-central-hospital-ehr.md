# Superseded: see participant-onboarding.md

This stub was created during Phase 2 planning and is superseded by
**`docs/runbooks/participant-onboarding.md`** (issue #15) — the generic
participant onboarding template, with Bahmni (the central hospital's EHR)
as worked example #1.

Its still-relevant content was folded in as follows:

- Goal / topology framing (HIE ≠ EHR, Mirth-mediated onboarding) →
  the template's "Invariants" section.
- Host #1 sizing prerequisite and the vanilla-OpenMRS fallback ladder →
  Gate A and ADR 0004 (decided: Bahmni Standard via Dynamic Memory;
  2.2 checkpoint passed, no fallback needed).
- Deployment / validation / rollback placeholders → the increment
  runbooks: `phase2-bahmni-deployment.md`, `phase2-mirth-channel.md`,
  `phase2-verification.md`.
- "Host #2 remains idle" constraint → unchanged
  (`docs/adr/0001-handoff.md`, binding until Phase 3).
