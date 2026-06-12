# Runbook: Phase 2.5 - Onboarding Verification (Participant -> Mirth -> HIE)

The Phase 2 closeout validation (issue #16) and the **Phase 3 acceptance-test
template**: proves a participant EHR's new patients and encounters reach the
CIN HIE via Mirth with correct identifiers and no impact on the existing
population. Interim documentation - folds into
`docs/runbooks/participant-onboarding.md` (2.6) as the "verify the
onboarding" step, with this script as the worked example.

## Scripted path

From the repo root, with the Phase 1 stack + Mirth channels (2.4) and the
participant EHR (2.2) running:

```bash
python3 scripts/verify-onboarding.py              # full round trip + cleanup
python3 scripts/verify-onboarding.py --keep       # leave the records in place
python3 scripts/verify-onboarding.py --timeout 300
```

Exit code 0 = PASS. Each run uses a fresh `VRFY-<UTC timestamp>` MRN, so
runs never collide and the script is repeatable even after a `--keep`.

What one run does and asserts:

1. **Baselines** - HIE total / Synthea-population / participant patient
   counts (Synthea population = identifiers under
   `https://github.com/synthetichealth/synthea`; 113 per Step 0 inventory).
2. **Same-human registration** - picks a deterministic donor Synthea
   patient *from the HIE* and registers identical demographics in the
   participant EHR under the fresh MRN: overlapping demographics, disjoint
   identifiers, exactly ADR 0003's model. (Includes the 2.3 gotcha
   workaround: OpenMRS FHIR2 drops `Address.line` on create; repaired via
   the REST person API.)
3. **Encounter** - creates a visit for that patient via the EHR's API.
4. **Arrival via Mirth** - polls the HIE until the patient appears under
   `https://lab.example/identifiers/bahmni-central|<MRN>` and the encounter
   under `.../bahmni-central/encounter|<visit UUID>` (default timeout 180s
   = 3 channel poll cycles), then asserts the encounter's `subject` is the
   HIE patient (identifier resolution, never hardcoded ids) and that the
   HIE patient carries *only* the participant identifier system (no
   EHR-internal identifiers leak).
5. **Population invariants** - Synthea count **unchanged** (the new patient
   is additive, not a collision); participant count exactly +1. Then prints
   the **intentional duplicate-person callout**: the HIE now holds two
   Patient resources for the same human (Synthea original + EHR-sourced),
   disjoint identifier systems - ADR 0003's staged Phase 3 MPI/dedup
   lesson, **not a bug**.
6. **Cleanup** (default) - voids the verification patient + encounter in
   the EHR *first* (so Mirth's polls stop returning them), then deletes
   encounter-before-patient from the HIE (HAPI enforces referential
   integrity on delete). `--keep` skips this.

## Phase 3 reuse (acceptance-test template)

All participant-specifics are env vars - rerun the same script against the
acquired CAH's OpenEMR by overriding:

| Variable | Phase 2 default (Bahmni) | Phase 3 (OpenEMR) |
|---|---|---|
| `EHR_FHIR_BASE` | `https://192.168.1.230/openmrs/ws/fhir2/R4` | OpenEMR FHIR R4 base |
| `EHR_REST_BASE` | `https://192.168.1.230/openmrs/ws/rest/v1` | (replace EHR-native calls*) |
| `EHR_USER` / `EHR_PASSWORD` | `superman` / `Admin123` | per participant |
| `EHR_IDENTIFIER_TYPE` | `Patient Identifier` | per participant |
| `PATIENT_SYSTEM` | `https://lab.example/identifiers/bahmni-central` | a new participant URI |
| `ENCOUNTER_SYSTEM` | `...bahmni-central/encounter` | a new participant URI |
| `HIE_FHIR_BASE` | `http://localhost:8080/fhir` | unchanged |
| `TIMEOUT_SECONDS` | `180` | per channel polling interval |

*The two OpenMRS-REST-specific steps (address repair, visit creation) are
the participant-specific seam - expect to swap those calls per EHR. The
FHIR registration, polling, assertions, and invariants are generic. This
maps to the parked identifier-registry question
(`docs/phase3-parking-lot.md` #2): each new participant needs its own
`*_SYSTEM` URIs and the Mirth transform that stamps them.

## Manual path

1. Note HIE counts: `GET <hie>/Patient?_summary=count` total, and with
   `&identifier=<synthea-system>|` and `&identifier=<participant-system>|`.
2. In the EHR UI (Bahmni: Registration -> New Patient), register a patient
   whose name/DOB/gender/address match an existing Synthea patient (find
   one: `GET <hie>/Patient?identifier=<synthea-system>|&_count=1`), with a
   fresh MRN like `VRFY-MANUAL-1`. Start a visit (e.g. OPD).
3. Wait up to ~3 minutes, then in the HIE confirm:
   `GET <hie>/Patient?identifier=<participant-system>|VRFY-MANUAL-1` -> 1 hit;
   `GET <hie>/Encounter?identifier=<participant-encounter-system>|<visit uuid>`
   -> 1 hit whose `subject.reference` is the patient found above.
4. Re-check the counts from step 1: Synthea unchanged, participant +1.
5. Observe (and do not "fix") the duplicate: searching the HIE by the
   donor's family name + birthdate returns two Patient resources with
   disjoint identifier systems. Intentional per ADR 0003.
6. Clean up: void patient + visit in the EHR UI, then
   `DELETE <hie>/Encounter/<id>` and `DELETE <hie>/Patient/<id>`.

## Result - 2026-06-12 (Phase 2 worked example)

PASS. Baselines total/synthea/participant = 129/113/16; donor Nickolas58
Sidney996 Abbott774 (b. 1956-03-23, HIE `Patient/61465`); patient
(`VRFY-20260612212134` -> `Patient/116770`) and encounter
(`Encounter/116771`) both arrived within the first poll cycle (~60s);
subject resolved by identifier; HIE patient carried exactly one identifier
system (`bahmni-central`); Synthea count unchanged at 113; participant
count 17 (+1); duplicate-person artifact confirmed and called out; cleanup
returned the HIE to 129 patients. Repeatability proven with two further
back-to-back runs (`VRFY-20260612212753`, `VRFY-20260612212904`, started
~60s apart) - both PASS with correct baselines after the cache fix below.
Full transcripts in the PR for this increment.

**Two early runs failed - by design value.** Both exposed real issues:

1. **Encounter-before-patient race in the 2.4 channels.** The encounter
   channel polled the new visit before the patient channel had synced its
   subject, and Mirth's destination `retryCount` does not re-run
   JavaScript Writer exceptions, so the message error-ed terminally.
   Fixed in the encounter channel (in-script wait for the subject, up to
   90s), documented as gotcha #5 in `docs/runbooks/phase2-mirth-channel.md`;
   the stranded message was recovered with a redeploy resync.
2. **HAPI's search cache made consecutive runs read stale counts.** HAPI
   reuses identical search results for ~60s
   (`reuse_cached_search_results_millis`), so a run started within a
   minute of the previous one read the *previous run's* mid-flight
   participant count as its baseline and failed the +1 invariant despite
   correct data. The script now sends `Cache-Control: no-cache` on every
   HIE request (HAPI honors it by skipping the cache). Keep this in the
   Phase 3 template - any assertion-by-count against a HAPI server needs
   it.
