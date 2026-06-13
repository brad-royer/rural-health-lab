# Runbook: Phase 3a.4 — Seed the Acquired-CAH (OpenEMR) Patient Panel

Registers the CAH's ~15-patient seed panel in OpenEMR per Gate I / ADR 0008:
demographics reused from the Synthea population, identifiers disjoint under
`https://lab.example/identifiers/openemr-cah`, with a deliberate three-way
overlap (CAH-0001..0005 are the same humans as Bahmni BAH-0001..0005).
Second worked example of the "seed the panel" template step. Depends on 3a.3.

## The OpenEMR divergences this increment surfaced (vs. Bahmni)

OpenEMR's API is materially harder to integrate than Bahmni's basic-auth
FHIR2 — this is the "OpenEMR is the unlike case" lesson 3a exists to find.
All captured here for the 3a.7 template and the Gate K ADR (0009):

1. **The REST/FHIR API is disabled by default.** Enable globals
   `rest_fhir_api`, `rest_api`, and (for backend-services system scopes)
   `rest_system_scopes_api`. UI path: Administration → Globals → **Connectors**
   tab. (If the UI is hard to find, the equivalent DB write is
   `UPDATE globals SET gl_value='1' WHERE gl_name IN (...)`.)
2. **No password grant** — only `client_credentials` (asymmetric,
   `private_key_jwt`) and `authorization_code`. So a confidential client with
   an RSA keypair is required; `scripts/openemr_oauth.py` does keygen, JWKS,
   registration, and RS384 JWT assertion → token (no PyJWT dep; uses
   `cryptography`).
3. **Newly registered clients are disabled** (`oauth_clients.is_enabled=0`) →
   token returns `invalid_client`. Enable via Administration → System → API
   Clients, or `UPDATE oauth_clients SET is_enabled=1 WHERE client_id=...`.
   `client_credentials` then grants `system/Patient.read` + `.write`.
4. **FHIR Patient create ignores a caller-supplied identifier** and
   auto-assigns its own (`pubpid`, defaulting to the internal pid). To pin
   the CAH MRN, the seeder creates via FHIR, captures the returned `uuid`
   (OpenEMR's create response is a custom `{"pid","uuid"}`, not a FHIR
   resource), then sets `pubpid=CAH-NNNN` in `patient_data` keyed by that
   uuid. Afterward OpenEMR's FHIR exposes and searches the MRN
   (`?identifier=CAH-NNNN`). This DB write is the OpenEMR-specific seam in
   an otherwise API-driven seeder.

## One-time OAuth setup

```bash
# After the API globals are enabled (step 1 above):
python3 scripts/openemr_oauth.py register      # keygen + register client
# Enable the client (step 3): UI, or
#   ssh ... "docker exec openemr-mysql-1 mariadb -uroot -proot openemr \
#     -e \"UPDATE oauth_clients SET is_enabled=1 WHERE client_id='<id>'\""
python3 scripts/openemr_oauth.py token          # should print a JWT
```
Client key + id are stored gitignored under `scripts/.secrets/`.

## Seeding

```bash
python3 scripts/seed-openemr-panel.py
```
- Panel pinned in `scripts/openemr-seed-manifest.json` (15 patients, overlap
  map). Idempotent: skips MRNs already present (`?identifier=CAH-NNNN`); a
  clean re-run prints 15× `skip`.
- Only demographics are sent; no Synthea/HAPI/Bahmni identifier.
- Needs SSH to the VM for the pubpid write (env `EHR_SSH_KEY`/`EHR_HOST`/
  `EHR_DB_CONTAINER`, defaulting to rhl-acquired-cah).

## Validation (2026-06-13)

- [x] 15 patients in OpenEMR (`SELECT COUNT(*) FROM patient_data` = 15).
- [x] Idempotent: second run = 15× skip, count unchanged.
- [x] Spot-check CAH-0005: `?identifier=CAH-0005` resolves; name, gender,
      DOB, and **street address** all stored (OpenEMR preserved `Address.line`,
      unlike Bahmni's FHIR2).
- [x] Bulk-import failure confirmed (Known Lessons #6): POST of a Synthea
      transaction bundle to the FHIR base → **HTTP 404 "Route not found"**
      (OpenEMR has no transaction-bundle endpoint; resource endpoints only).
- [x] Three-way overlap recorded for 3b (parking lot): CAH-0001..0005 = same
      Synthea humans as BAH-0001..0005.

## Rollback

```bash
# Remove the seeded patients (DB; OpenEMR has no FHIR Patient DELETE):
ssh -i <key> ubuntu@192.168.1.189 \
  "docker exec openemr-mysql-1 mariadb -uroot -proot openemr \
   -e \"DELETE FROM patient_data WHERE pubpid LIKE 'CAH-%';\""
```
Affects only OpenEMR; nothing on the HIE or Bahmni.
