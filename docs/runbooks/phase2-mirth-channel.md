# Runbook: Phase 2.4 - CIN Mirth Instance + Bahmni -> HIE Channels

Stands up the CIN's single Mirth Connect instance and the two outbound
channels that onboard Bahmni to the HIE per Gate C
(`docs/adr/0005-gate-c-integration-source-and-direction.md`) and ADR 0003.
Interim documentation - folds into `docs/runbooks/participant-onboarding.md`
(2.6) as the "wire the participant into the HIE" step.

## Goal

Patients and encounters created in Bahmni appear in the HAPI hub within
~60s, keyed on Bahmni-specific identifier systems, without ever touching
HAPI resource ids or Bahmni data (outbound only; Bahmni is read-only to
the channels).

## Architecture

```
Bahmni (rhl-central-hospital VM, 192.168.1.230)
  OpenMRS FHIR2 R4 API  <-- poll every 60s (basic auth, self-signed TLS)
        |
  Mirth Connect 4.5.2 ("mirth" container, Phase 1 compose stack)
        |  transform: strip Bahmni internals, stamp identifier system URIs
        v
  HAPI hub (http://hapi-hub:8080/fhir, same compose network)
        conditional PUT keyed on identifier (upsert; HAPI assigns ids)
```

- Patient channel key: `https://lab.example/identifiers/bahmni-central|<MRN>`
- Encounter channel key:
  `https://lab.example/identifiers/bahmni-central/encounter|<Bahmni encounter UUID>`,
  subject resolved by identifier search in HAPI (never hardcoded ids).

## Prerequisites

- Phase 1 stack running (`compose/docker-compose.yml`: hapi-hub + db).
- Bahmni running with the seed panel (2.2/2.3 runbooks).

## Automation path

1. **Start Mirth** (from `compose/`):

   ```bash
   docker compose up -d mirth
   # API up when this returns 200 (first boot takes ~30-60s):
   curl -sk -u admin:admin -H "X-Requested-With: OpenAPI" \
     -o /dev/null -w "%{http_code}\n" https://localhost:8443/api/server/version
   ```

   Image is pinned to `nextgenhealthcare/connect:4.5.2` - the **last
   open-source Mirth release** (4.6+ went commercial; Docker Hub tags stop
   at 4.5.2). No vendor patches will ever arrive for it: treat any future
   CVE as a Phase 3 re-evaluation trigger (ADR 0005).

2. **Import + deploy the channels** (from the repo root):

   ```bash
   scripts/deploy-mirth-channels.sh
   ```

   Idempotent: import is `PUT /api/channels/<id>?override=true` keyed on
   the fixed channel ids inside `compose/mirth/channels/*.xml`; redeploy
   clears poll state and triggers a full resync, which the conditional
   upserts absorb (verified: repeated resyncs left HAPI counts unchanged,
   only bumping resource `versionId`).

## Manual path

Mirth Administrator (GUI): download the Administrator Launcher from
`https://localhost:8443` on any LAN host, log in (`admin`/`admin` -
well-known default, change before anything production-like), then
Channels -> Import Channel -> select each XML from
`compose/mirth/channels/` -> Deploy All Channels. The REST steps above are
the scripted equivalent; channel edits made in the GUI must be re-exported
into the repo or they're lost on the next scripted deploy.

## Validation

```bash
# Channel stats (error must be 0):
scripts/deploy-mirth-channels.sh   # stats block at the end, or:
curl -sk -u admin:admin -H "X-Requested-With: OpenAPI" \
  https://localhost:8443/api/channels/statistics

# HIE-side counts: 16 bahmni-central patients; Synthea population untouched.
curl -s "http://localhost:8080/fhir/Patient?_summary=count"                # 129 = 113 Synthea + 16 Bahmni
curl -s "http://localhost:8080/fhir/Patient?identifier=https%3A%2F%2Flab.example%2Fidentifiers%2Fbahmni-central%7C&_summary=count"   # 16

# End-to-end smoke (what 2.5 will script): create a visit in Bahmni, then
# watch it arrive in HAPI within ~60s with the subject resolved:
curl -s "http://localhost:8080/fhir/Encounter?identifier=https%3A%2F%2Flab.example%2Fidentifiers%2Fbahmni-central%2Fencounter%7C&_summary=count"
```

Validated 2026-06-12: 16/16 patients synced (0 errors), test OPD visit for
`BAH-0001` arrived with class `AMB`, type `OPD`, and
`subject -> Patient/116752` (HAPI's own id for BAH-0001, found by
identifier search). `Encounter.status` arrives as `unknown` while the
Bahmni visit is still open - OpenMRS behavior, passed through as-is.

**Intentional artifact (ADR 0003):** HAPI now holds two Patient resources
for each seed-panel human - the Synthea original and the Bahmni-sourced
copy, under disjoint identifier systems. This is the staged Phase 3
MPI/dedup lesson, not a bug; 2.5's verification must call it out.

## Channel design notes / gotchas (measured 2026-06-12)

1. **Java 17 module wall:** channel scripts cannot use `java.net.URL`
   HTTP(S) connections - Rhino gets `IllegalAccessException` because the
   JDK's internal `HttpURLConnection` impl classes aren't exported to the
   unnamed module. Use the Apache HttpClient classes bundled with Mirth
   (`org.apache.http.*`), as both channels do. This binds all future
   channel work on this instance.
2. **Identifier system stamping happens here.** OpenMRS stores no
   `identifier.system` (ADR 0003 dated update); the transform maps the
   "Patient Identifier" type -> `bahmni-central` URI. The type->URI
   mapping is integration-layer configuration (parked registry question:
   `docs/phase3-parking-lot.md` #2).
3. **OpenMRS address extension normalized.** Street lines arrive as the
   proprietary `http://fhir.openmrs.org/ext/address` extension, not
   `Address.line`; the Patient transform folds `#address1/#address2` into
   standard `line[]` and drops the extension.
4. **Encounter envelope is minimal** (identifier, status, class, type,
   period, subject). Bahmni-local references (location, participant,
   partOf visit) are dropped - their targets don't exist in the HIE.
5. **Encounter-before-patient race - thrown JS errors are terminal.** The
   two channels poll independently, so an encounter can arrive before its
   patient has synced. Mirth's destination `retryCount` does NOT re-run
   JavaScript Writer exceptions - a throw marks the message ERROR
   permanently (found by 2.5's verification: the encounter channel
   error-ed a visit whose patient synced 30s later, and it never
   recovered until a redeploy resync). The destination script therefore
   waits in-process for the subject (up to 90s, one patient-channel cycle
   plus margin) before failing the message. If a message does end up
   ERROR'd, a redeploy (`scripts/deploy-mirth-channels.sh`) forces a full
   resync that re-delivers it.
5. **Credentials are hardcoded lab defaults** in the committed channel XML
   (`superman`/`Admin123` toward Bahmni; HAPI is unauthenticated). Fine
   for this synthetic lab; production delta below.

## Production delta (for 2.6)

- OAuth/mTLS between participants, Mirth, and the HIE (Keycloak arrives
  Phase 3) instead of basic auth + trust-all TLS toward a self-signed cert.
- Mirth backed by Postgres instead of embedded Derby; admin password
  rotated from the `admin`/`admin` default; channel credentials in Mirth's
  configuration map, not channel source.
- Message-level audit retention policy (channel message storage is
  PRODUCTION mode here, but pruning/audit is unconfigured).

## Rollback

```bash
# Channels only (stop the flow, keep Mirth):
for id in 5e316901-73b3-4523-bf07-b0d8e2f7bf10 84b28835-c32b-4dd3-a62f-a829e1c9e1cd; do
  curl -sk -u admin:admin -H "X-Requested-With: OpenAPI" -X POST \
    "https://localhost:8443/api/channels/$id/_undeploy"
done

# Whole Mirth instance (from compose/):
docker compose stop mirth                 # keep state
docker compose rm -sf mirth               # remove container, keep volume
docker volume rm compose_mirth-appdata    # erase Mirth state entirely

# HIE-side cleanup of synced resources (if a clean slate is needed):
# delete by identifier search - never touches Synthea resources.
curl -s -X DELETE "http://localhost:8080/fhir/Encounter?identifier=https%3A%2F%2Flab.example%2Fidentifiers%2Fbahmni-central%2Fencounter%7C&_cascade=delete"
curl -s -X DELETE "http://localhost:8080/fhir/Patient?identifier=https%3A%2F%2Flab.example%2Fidentifiers%2Fbahmni-central%7C"
```

None of this touches Bahmni (`rhl-central-hospital`) or Host #2.
