# Runbook: Phase 2.3 - Seed the Bahmni Patient Panel

Registers the central hospital's ~15-patient seed panel in Bahmni per
Gate B (`docs/adr/0003-gate-b-panel-identity-strategy.md`): demographics
reused from the Synthea rural-TX population, identifiers fully disjoint
(Bahmni-issued MRNs, no Synthea/HAPI identifier ever copied in). Interim
documentation - folds into `docs/runbooks/participant-onboarding.md` (2.6)
as the "seed the participant's panel" step.

## Goal

A small, scripted, idempotent, re-runnable seed panel in Bahmni
(increment 2.3, issue #14). No bulk Synthea import - the full population
stays in HAPI only (Known Lessons #6).

## Prerequisites

- Increment 2.2 complete: Bahmni `emr` profile running on
  `rhl-central-hospital` (`docs/runbooks/phase2-bahmni-deployment.md`).
- `synthea/output/fhir/*.json` present locally (regenerate via
  `scripts/generate-synthea.sh` if missing - output is gitignored).
- Python 3 on the workstation (stdlib only, no pip installs).

## Scripted path (automation)

From the repo root on the workstation (WSL2):

```bash
python3 scripts/seed-bahmni-panel.py            # default --base-url https://192.168.1.230
```

- The panel is pinned in `scripts/seed-panel-manifest.json`: 15 living
  patients (sorted `synthea/output/fhir/*.json`, first 15 alive), each
  with a fixed script-assigned MRN `BAH-0001`..`BAH-0015` under Bahmni's
  required **"Patient Identifier"** type. Fixed MRNs - rather than
  Bahmni's IDGEN auto-minting (`ABC2xxxxx`, what the registration UI
  uses) - are what make re-runs idempotent: the script checks
  `GET /openmrs/ws/fhir2/R4/Patient?identifier=<MRN>` and skips existing
  patients, so a clean re-run prints 15x `skip` / `address: ok` and
  changes nothing.
- Only demographics (name, gender, DOB, address) are sent. The
  manifest's `source_file` field is repo-side traceability only.
- Credentials come from `BAHMNI_USER`/`BAHMNI_PASSWORD` env vars,
  defaulting to the well-known Bahmni lab defaults
  (`superman`/`Admin123`).

## Manual path

In the Bahmni UI at `https://192.168.1.230/` (login per 2.2 runbook):
Registration -> New Patient. For each manifest entry, enter the name,
gender, birth date, and address, and **replace the auto-generated entry
in the Patient ID field with the manifest MRN** (e.g. `BAH-0003`) so the
identifier matches what the script (and later the 2.5 verification)
expects. Save.

## Verification

```bash
# 16 = 15 seeded + the 2.2 smoke-test patient
curl -sk -u superman:Admin123 \
  "https://192.168.1.230/openmrs/ws/fhir2/R4/Patient?_summary=count" \
  -H "Accept: application/fhir+json" | python3 -c \
  "import json,sys; print(json.load(sys.stdin)['total'])"

# Spot-check one patient: MRN under "Patient Identifier", street address present
curl -sk -u superman:Admin123 \
  "https://192.168.1.230/openmrs/ws/rest/v1/patient?q=BAH-0005&v=custom:(person:(preferredAddress:(address1,cityVillage,preferred)))"
```

And re-run the script: it must report `created=0 ... failed=0` with
`address: ok` on every line (full idempotency).

## Known limitations / why no bulk Synthea import (measured 2026-06-12)

These are the concrete failures behind Known Lessons #6's "Synthea
bundles do not load cleanly into Bahmni" - captured by experiment, for
the 2.6 runbook's production-delta notes:

1. **No transaction endpoint.** `POST <base>/openmrs/ws/fhir2/R4` with a
   Synthea bundle (type `transaction`) returns **HTTP 400, `HAPI-0287:
   This is the base URL of FHIR server...`** - the OpenMRS FHIR2 module
   serves individual resource endpoints only and cannot process bundles
   at all.
2. **Raw Synthea Patient resources are rejected.** `POST .../R4/Patient`
   with an unmodified Synthea Patient returns **HTTP 422, `'Patient#null'
   failed to validate with reason: Select a preferred identifier`**:
   Synthea identifiers carry system URIs
   (`https://github.com/synthetichealth/synthea`,
   `http://hospital.smarthealthit.org`, `http://hl7.org/fhir/sid/us-ssn`)
   but no OpenMRS identifier *type*, and FHIR2 maps identifiers by type,
   not by system URI - so none qualify as the required preferred
   identifier.
3. **FHIR2 drops `Address.line` on create.** City/state/zip persist, but
   `address1` is stored null and the address is left non-preferred
   (observed on `bahmni/openmrs:1.1.3`). The script repairs this through
   the OpenMRS REST API (`POST /ws/rest/v1/person/<uuid>/address/<uuid>`
   with `address1` + `preferred: true`) as an idempotent second step.
   The clinical-resource analog of this gap (unmapped concepts for
   Observations/Conditions) is why even per-resource bulk import of the
   rest of a Synthea bundle is out of scope.

**Identifier system URI note:** OpenMRS stores no `system` URI on
identifiers - Bahmni's FHIR output carries only the identifier type
("Patient Identifier") and value. The ADR 0003 system URI
`https://lab.example/identifiers/bahmni-central` is therefore stamped by
the Mirth transform in increment 2.4 (mapping type -> URI), not stored in
Bahmni. Recorded as a dated update in ADR 0003.

## Rollback

Void all seeded patients (FHIR DELETE = OpenMRS void, reversible from the
DB; the 2.2 smoke-test patient is untouched):

```bash
for i in $(seq -w 1 15); do
  uuid=$(curl -sk -u superman:Admin123 \
    "https://192.168.1.230/openmrs/ws/fhir2/R4/Patient?identifier=BAH-00$i" \
    -H "Accept: application/fhir+json" | python3 -c \
    "import json,sys; b=json.load(sys.stdin); print(b['entry'][0]['resource']['id'] if b.get('total') else '')")
  [ -n "$uuid" ] && curl -sk -u superman:Admin123 -X DELETE \
    "https://192.168.1.230/openmrs/ws/fhir2/R4/Patient/$uuid" -o /dev/null -w "voided BAH-00$i\n"
done
```

Note before re-seeding after a void: a voided patient's identifier stays
in the DB while `identifier=` searches stop matching it, so the script
will attempt a fresh create of the same MRN - whether OpenMRS accepts
that (vs. rejecting a duplicate identifier) is untested. If it rejects,
either un-void the patients in OpenMRS admin or use the full reset: the
2.2 runbook's `down -v` rollback erases all Bahmni data.
