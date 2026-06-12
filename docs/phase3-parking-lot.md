# Phase 3 Parking Lot — Deferred Identity / MPI / Dedup Questions

Per `docs/phase2-kickoff-prompt.md` (Hard Rule #5) and Known Lessons #5
(`docs/adr/0001-handoff.md`): MPI/EMPI matching, record dedup, and
identifier reconciliation are explicitly out of scope for Phase 2. When a
question of this shape surfaces during Phase 2 work, record it here — with
enough context for Phase 3 to act on — and move on. Do not solve it now.

## Entry format

- **Date / increment:**
- **Question:**
- **Why it surfaced:**
- **Phase 3 relevance:**

## Entries

### 1. What does cross-system patient matching key on, given lossy demographics?

- **Date / increment:** 2026-06-12 / 2.3
- **Question:** When Phase 3 links the "same human" across HAPI (Synthea
  identifiers) and Bahmni (`BAH-NNNN` MRNs), what attributes can matching
  actually rely on — and how does it tolerate per-system data loss?
- **Why it surfaced:** Seeding the panel showed demographics do not
  round-trip faithfully even in a controlled copy: OpenMRS FHIR2 dropped
  the street line on create (repaired via REST, see
  `docs/runbooks/phase2-seed-panel.md`), Synthea geolocation extensions
  and name prefixes were deliberately not carried over, and OpenMRS
  stores no identifier system URI. The two records for the same human
  already differ in more than just identifiers.
- **Phase 3 relevance:** Deterministic match on name+DOB+gender works for
  this clean seed panel but is exactly the assumption real MPIs can't
  make; Phase 3 should decide field weights / normalization (and whether
  address participates at all, given it's the lossiest field).

### 2. Identifier *type* vs identifier *system URI* — where does the mapping live?

- **Date / increment:** 2026-06-12 / 2.3
- **Question:** OpenMRS identifies identifiers by local *type* ("Patient
  Identifier"), not by FHIR `system` URI; the
  `https://lab.example/identifiers/bahmni-central` URI exists only in the
  Mirth transform (2.4). Should the HIE maintain a registry of
  participant identifier systems (type→URI mappings per participant), and
  who owns it when the next EHR (OpenEMR, Phase 3) onboards?
- **Why it surfaced:** Verified during 2.3 that Bahmni's FHIR output
  carries no `system` on identifiers (see ADR 0003 update), so the URI
  binding is integration-layer configuration, not source-system data.
- **Phase 3 relevance:** OpenEMR onboarding repeats this exact question;
  a per-participant identifier-system registry is the difference between
  the onboarding runbook (2.6) being generic vs. Bahmni-specific.

### 3. Same-MRN reuse after voiding — is a voided identifier retired or reusable?

- **Date / increment:** 2026-06-12 / 2.3
- **Question:** If a Bahmni patient is voided and the MRN re-created (the
  seed script's rollback + re-seed path), is that the "same" patient for
  the HIE's purposes? HAPI-side resources created by 2.4's conditional
  upsert would silently re-attach to the new record.
- **Why it surfaced:** Writing the 2.3 rollback procedure (FHIR DELETE =
  OpenMRS void; identifier searches stop matching but the value stays in
  the DB).
- **Phase 3 relevance:** Real registries treat MRN reuse as a
  patient-safety hazard; the HIE's identifier registry (entry #2) should
  state a policy (identifiers are never reused) rather than inherit
  whatever the source EHR happens to allow.
