# Runbook: Phase 3a.6 — Onboarding Verification (OpenEMR → CAH Mirth → HIE)

Proves the participant→Mirth→HIE round trip for OpenEMR using the **same**
generalized verifier as Phase 2's Bahmni — the realization of the Phase 3
acceptance-test template. Depends on 3a.5.

## The generalized verifier

`scripts/verify-onboarding.py` is now EHR-agnostic: one generic flow (donor
selection, HIE polling, invariants, duplicate callout) with the EHR-specific
operations behind a **pluggable backend** (`scripts/ehr_backends.py`),
selected by `--ehr`:

```bash
python3 scripts/verify-onboarding.py --ehr bahmni    # Phase 2 worked example
python3 scripts/verify-onboarding.py --ehr openemr   # Phase 3a
python3 scripts/verify-onboarding.py --ehr openemr --keep --timeout 360
```

Each backend implements the seam: `register_patient(donor, mrn)`,
`create_encounter(handle)`, `delete(handle, enc_value)`. The generic flow,
HIE-side assertions, and the three-way duplicate callout are shared. Adding a
Phase 3+ EHR = adding a backend class, not touching the flow — which is the
template proving itself.

## OpenEMR backend seams (why it differs from Bahmni)

Bahmni's backend is plain OpenMRS REST over basic auth. OpenEMR's needs three
workarounds, all genuine OpenEMR findings (captured for the template):

1. **Auth: SMART Backend Services OAuth** (`openemr_oauth.py`), not basic
   auth — OpenEMR has no password grant (ADR 0009).
2. **Patient register: FHIR create + `pubpid` via DB.** OpenEMR's FHIR create
   ignores a supplied identifier and assigns its own; the MRN is pinned by
   setting `pubpid` in `patient_data` keyed by the returned uuid (as in the
   3a.4 seeder).
3. **Encounter create: DB insert.** OpenEMR's **FHIR Encounter is read-only**
   (`read`/`search-type` only — no `create`), and its **standard REST API
   returns 403 under `client_credentials`** (it needs a user context a machine
   token doesn't have). So the encounter is inserted into `form_encounter` +
   `forms`, which OpenEMR's read-only FHIR Encounter API then surfaces to the
   CAH Mirth. This is the headline OpenEMR integration limitation: no
   machine-auth API path to create an encounter.

The DB seam uses SSH to the VM (`EHR_SSH_KEY` / `EHR_HOST` /
`EHR_DB_CONTAINER`), the same access the 3a.4 seeder uses. Production would use
a service account via authorization_code, or HL7/bulk ingestion, instead.

## Result — 2026-06-14

**PASS**, with only `--ehr openemr` (no flow/logic changes vs. the Bahmni
run — only the backend differs, which is the point). Donor Nickolas58
Abbott774 (b. 1956-03-23, HIE `Patient/61465`); registered in OpenEMR as
`VRFY-20260614050058`; patient and encounter both arrived via the CAH Mirth
across the cross-host boundary (`Patient/116794`, `Encounter/116795`);
subject resolved by identifier; identifier systems correct (`openemr-cah`);
Synthea population unchanged at 113; participant count 15 → 16; cleanup
returned the HIE to 144. The three-way duplicate cohort from 3a.5 remains as
the standing ADR 0008 artifact.

## Phase 3 reuse

The parameter sheet (`participant-onboarding.md`) + a new backend class is all
a future participant needs. `--ehr` + env (`OPENEMR_BASE`, `PATIENT_SYSTEM`,
`ENCOUNTER_SYSTEM`, `EHR_SSH_KEY/HOST/DB_CONTAINER`, `TIMEOUT_SECONDS`) drive
it; the generic flow and assertions never change.

## Manual path

Create a patient + visit by hand in the OpenEMR UI (matching an existing
Synthea human, with a fresh external ID), wait ~2 poll cycles, then confirm in
the HIE: `Patient?identifier=<openemr-cah>|<id>` (1 hit) and
`Encounter?identifier=<openemr-cah/encounter>|<uuid>` (1 hit, subject = that
patient); Synthea count unchanged. Clean up by voiding in OpenEMR + deleting
the HIE resources.
