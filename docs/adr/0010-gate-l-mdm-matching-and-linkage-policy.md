# ADR 0010 - Gate L: MDM Matching Rules & Linkage Policy

## Status
Accepted - 2026-06-15

## Context
Phase 3b (`docs/phase3b-kickoff-prompt.md`, Gate L) resolves the deferred
record-linkage problem against the three-way duplicate cohort 3a built (same
human as a Synthea original + `bahmni-central|BAH-000x` + `openemr-cah|CAH-000x`,
parking-lot #1/#4). 3b.1 enables HAPI's built-in MDM; Gate L fixes the
matching rules and the linkage/identifier policy.

## Decision
1. **HAPI built-in MDM, link-not-merge.** MDM creates golden-resource
   Patients and `Patient.link` associations with MATCH / POSSIBLE_MATCH; it
   never deletes, merges away, or overwrites source Patient resources (Hard
   Rule #2). Sources stay exactly as the participants wrote them.
2. **Matching rules** (`compose/hapi-config/mdm-rules.json`):
   - **Candidate search** narrows by `birthdate` (only same-DOB patients are
     compared).
   - **Match fields** (exact `STRING` matchers): `name.given`, `name.family`,
     `birthDate`, `gender`.
   - **`matchResultMap`:** all four agree -> **MATCH**; given+family+birthDate
     (gender unknown/differs) -> **POSSIBLE_MATCH**.
   - **Address deliberately excluded** - it is the lossiest field
     (parking-lot #1: Bahmni's FHIR2 dropped `line`, OpenEMR kept it, Synthea
     carries geo-extensions), so including it would create false negatives.
     Exact name+DOB+gender is sound *here* because the panels were seeded from
     copied Synthea demographics; the rules file is the knob to revisit when
     data is dirtier (Known Lessons #3).
3. **Identifier-system registry + no-reuse policy** (resolves parking-lot
   #2/#3/#5): the HIE owns the participant identifier-system registry - the
   `type -> URI` mapping is integration-layer config stamped by each
   participant's Mirth (`bahmni-central`, `openemr-cah`), never source data.
   **Identifiers are never reused**: a voided/retired participant MRN is not
   re-issued, so HIE resources never silently re-attach to a different human.
   The HIE enterprise identifier (EID) system is
   `https://lab.example/identifiers/hie-eid`.

## Rationale
- HAPI MDM is built into the running image (no new service), standards-aligned
  (golden record + `Patient.link`), and non-destructive - the right fit for
  "decide what to do about the duplicates" without losing source fidelity.
- Matching on name+DOB+gender and excluding address is the direct lesson from
  parking-lot #1: deterministic match works on the clean seed panels, and
  address is exactly the field that wouldn't round-trip.

## Consequences
- **Golden records form on demand, not automatically here.** The participant
  channels re-`PUT` identical patient content each poll (no-op updates -> no
  new version -> no MDM trigger), and the Synthea population is static. So
  3b.2 must `$mdm-submit` the full population to force linkage and verify the
  three-way links.
- **Enabling MDM requires subscriptions** (rest-hook), now on - this is the
  channel 3b.3's `Encounter` notification builds on.
- **Config gotcha:** `mdm_rules_json_location` is loaded by Spring's
  ResourceLoader - an unprefixed/absolute path is read as a *classpath*
  resource and crash-loops HAPI; the mounted file needs the `file:` prefix
  (`file:/configs/mdm-rules.json`). Documented in the runbook.

## Related
- `docs/phase3b-kickoff-prompt.md` - Gate L
- `docs/phase3-parking-lot.md` - #1 (matching keys), #2/#3/#5 (registry/reuse), #4 (three-way)
- `docs/runbooks/phase3b-hapi-mdm.md`
- Increment 3b.1 (#43); linkage run/verify in 3b.2 (#44)
