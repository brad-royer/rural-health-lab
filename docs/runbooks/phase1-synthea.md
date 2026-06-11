# Runbook: Phase 1.4 — Synthea Synthetic Population (Hub Only)

## What this is

Generates a synthetic **rural Texas patient population** with MITRE Synthea
and loads it into the **hub only** (`hapi-hub`, `http://localhost:8080/fhir`)
from the Phase 1.1–1.3 stack (`docs/runbooks/phase1-hapi-hub.md`).

This is **increment 4 of Phase 1** per `docs/adr/0001-handoff.md` and GitHub
issue #7.

**Out of scope for this increment:** spokes (`spoke-a`, `spoke-b`), Mirth
Connect, Keycloak, Medplum. The population generated here is the substrate
for later increments (`CareTeam`, `Organization`/`OrganizationAffiliation`,
`Subscription`-based encounter notifications).

## Why this data isn't committed to the repo

Synthea output is **synthetic**, not real PHI — but it is *realistic in
shape*: plausible names, addresses, birthdates, SSNs (synthetic), and
free-text clinical narratives. Per `CLAUDE.md` rule #1 ("synthetic data only,
no real PHI ever") this lab treats PHI-*shaped* data the same as real PHI for
handling purposes, even though it's fake. The fix is **reproducibility, not
secrecy**:

- Generation uses a **fixed seed** (`-s 1`, default). Re-running
  `scripts/generate-synthea.sh` with the same `SYNTHEA_VERSION`,
  `POPULATION`, `SEED`, and `STATE` produces **byte-identical output**.
- `synthea/output/` (generated bundles) and `synthea/.cache/` (the
  downloaded Synthea jar) are gitignored.
- Only the **scripts and this runbook** are committed — the data is
  regenerated on demand, anywhere, by anyone with this repo.

## Components

| Script | Purpose |
|---|---|
| `scripts/generate-synthea.sh` | Downloads `synthea-with-dependencies.jar` (pinned to `v4.0.0`, cached in `synthea/.cache/`) and runs it in a `eclipse-temurin:21-jdk` container to generate FHIR R4 transaction bundles under `synthea/output/fhir/`. No local Java install required. |
| `scripts/load-to-hub.sh` | POSTs the generated bundles to `http://localhost:8080/fhir` as FHIR transactions, in two ordered passes (system bundles, then patient bundles — see below), then prints resource counts. |

## Why JDK 21 / Synthea v4.0.0

Synthea `v4.0.0` (March 2025) raised its minimum Java requirement to **JDK
17** (previously JDK 11) and added US Core 7 support to the FHIR R4
exporter. `eclipse-temurin:21-jdk` is the current LTS release and satisfies
the `>=17` requirement — pinned explicitly (both the Synthea version and the
JDK image) so this doesn't silently break when `:latest`-style tags move.

The jar is downloaded once and cached at
`synthea/.cache/synthea-with-dependencies-<version>.jar` — re-running
`generate-synthea.sh` won't re-download it unless you bump
`SYNTHEA_VERSION` or delete the cache.

## Prerequisites

- Phase 1.1–1.3 stack up and healthy (`cd compose && docker compose up -d`;
  see `docs/runbooks/phase1-hapi-hub.md`). The hub must respond `200` on
  `http://localhost:8080/fhir/metadata`.
- Docker available (used to run both the Synthea generator and, indirectly,
  `curl`/`python3` from the host for loading/validation).
- `curl` and `python3` available on the host (used by `load-to-hub.sh` for
  posting bundles and parsing `_summary=count` JSON responses).
- Outbound internet access to `github.com` (to download the Synthea jar) and
  Docker Hub / GHCR (to pull `eclipse-temurin:21-jdk`, ~400 MB first pull).

## Step 1 — Generate the population

```bash
scripts/generate-synthea.sh
```

Defaults: `POPULATION=100`, `SEED=1`, `STATE=Texas`, `SYNTHEA_VERSION=v4.0.0`.
Override via env vars, e.g. a smaller smoke-test run:

```bash
POPULATION=10 scripts/generate-synthea.sh
```

**What happens:**

1. Downloads `synthea-with-dependencies.jar` from
   `https://github.com/synthetichealth/synthea/releases/download/v4.0.0/synthea-with-dependencies.jar`
   into `synthea/.cache/` (skipped if already cached).
2. Runs `java -jar synthea-with-dependencies.jar -p 100 -s 1
   --exporter.fhir.export=true --exporter.hospital.fhir.export=true
   --exporter.practitioner.fhir.export=true Texas` inside
   `eclipse-temurin:21-jdk`, with `synthea/output/` bind-mounted as the
   container's `output/` directory.
3. Writes FHIR R4 transaction bundles to `synthea/output/fhir/`:
   - `hospitalInformation<N>.json` — `Organization`/`Location` resources for
     generated hospitals/clinics.
   - `practitionerInformation<N>.json` — `Practitioner`/`PractitionerRole`
     resources.
   - One bundle per generated patient (named after the patient, e.g.
     `<FirstName>_<LastName>_<id>.json`), each a `Bundle` with
     `type: transaction` containing `Patient`, `Encounter`, `Condition`,
     `Observation`, `MedicationRequest`, etc.

**Expected runtime:** Synthea generation for `-p 100` typically takes
**2–5 minutes** depending on host CPU — Synthea simulates each patient's
entire life history through the Generic Module Framework, not just a single
snapshot. A smaller `POPULATION` (e.g. 10) for a first smoke test is
recommended.

**Most likely failure modes:**

- **`curl: (22) The requested URL returned error: 404`** when downloading
  the jar — `SYNTHEA_VERSION` doesn't match an actual GitHub release tag.
  Check https://github.com/synthetichealth/synthea/releases for valid tags.
- **Container exits immediately with a Java version error** — if
  `JAVA_IMAGE` is overridden to something below JDK 17, Synthea v4.0.0+ will
  refuse to start (`UnsupportedClassVersionError`). Use the default
  `eclipse-temurin:21-jdk` or any `>=17` JDK image.
- **Empty `synthea/output/fhir/`** — Synthea also writes CSV, CCDA, and other
  exporter formats to `synthea/output/` by default; if `fhir/` is missing or
  empty, check the container's stdout for exporter errors (it prints
  progress per patient, e.g. `Patient ... 45 y/o ... Diabetes Mellitus`,
  ending with a summary line).

## Step 2 — Load into the hub

```bash
scripts/load-to-hub.sh
```

Override the target hub URL if needed:

```bash
HUB_URL=http://localhost:8080/fhir scripts/load-to-hub.sh
```

### Why load order matters

This is the core lesson of this increment, not an implementation detail.

The two bundle "shapes" in `synthea/output/fhir/` are **not the same
`Bundle.type`**, and that distinction matters:

- `hospitalInformation*.json` and `practitionerInformation*.json` are
  **batch** bundles (`Bundle.type = batch`). Per
  [FHIR R4 §3.2.1.7 Batch/Transaction](https://hl7.org/fhir/R4/http.html#transaction),
  batch processing gives **no atomicity guarantee** — "the success or
  failure of one entry SHOULD NOT alter the success or failure of another
  entry." Each `Organization`/`Practitioner` entry is POSTed independently
  with `ifNoneExist` (a conditional create), so individual entries can fail
  without failing the whole bundle, and re-running the same batch bundle
  against an already-loaded hub is idempotent.
- Each per-patient bundle (e.g. `Abdul218_Schoen8_*.json`) is a
  **transaction** bundle (`Bundle.type = transaction`). Per the same spec
  section, transaction processing is **all-or-nothing**: "servers SHALL
  either accept all actions and return a `200`/`201`... or reject all
  resources and return an HTTP `400`/`500`-type response." Resources
  created *within the same transaction bundle* reference each other via
  `urn:uuid:...` references, which the server resolves and rewrites as it
  processes the bundle — those work regardless of load order.

The load-order requirement below is **not** about atomicity guarantees on
the system (batch) bundles themselves — batch entries don't roll back as a
unit either way. It's about a **cross-bundle reference dependency**: each
patient transaction bundle's `Encounter`, `Condition`, etc. reference
`Organization` and `Practitioner` resources defined in the *separate*
`hospitalInformation*.json` / `practitionerInformation*.json` bundles — by a
**fixed reference** (e.g. `Organization/abc-123`), not `urn:uuid`. A
transaction bundle's reference resolution only looks at resources **already
persisted in the server's store** plus other entries *within that same
bundle* — it cannot see into a different bundle. So if the
`Organization`/`Practitioner` resources a patient bundle references haven't
been persisted to the hub yet (via the system batch bundles, processed
first), the transaction's reference resolution fails for that entry and —
because transaction semantics are all-or-nothing — **the entire patient
bundle is rejected** (typically `400 Bad Request` with an
`OperationOutcome` citing the unresolvable reference).

So:

1. **System bundles first** (`hospitalInformation*.json`,
   `practitionerInformation*.json`) — these create the `Organization`,
   `Location`, `Practitioner`, `PractitionerRole` resources with **stable
   IDs** that patient bundles will reference.
2. **Patient bundles second** — now their `Organization`/`Practitioner`
   references resolve against resources already in the hub.

`load-to-hub.sh` enforces this:

- It globs `hospitalInformation*.json` and `practitionerInformation*.json`
  first and POSTs them.
- If **any** system bundle fails, it **aborts before touching patient
  bundles** — loading patient bundles against a hub missing reference data
  would just produce a wall of failures, and the failures wouldn't tell you
  anything you don't already know (the root cause is the system bundle
  failure).
- It then POSTs every remaining `*.json` in `synthea/output/fhir/` as
  patient bundles, reporting per-file `OK`/`FAIL` with HTTP status, and a
  summary count.

### CMS Health Tech Ecosystem framing

This load-order dependency mirrors a real CIN/ACO **partner onboarding**
flow: before a partner organization's patient panel (clinical/demographic
"transactional" data) can be ingested into the hub's HIE, the **provider
directory / endpoint directory** data — the partner `Organization`,
`Location`, and `Practitioner` records ("reference" or "master" data) — must
already exist, so attribution and care-team relationships can resolve.
Skipping this step is a common real-world cause of failed bulk-data loads
during ACO onboarding.

## Validation

### 1. Confirm the hub is up

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/fhir/metadata
```

Expected: `200`. If not, bring up the compose stack first
(`docs/runbooks/phase1-hapi-hub.md`).

### 2. Run the load and review the summary

`load-to-hub.sh` prints, at the end:

```
=== Summary ===
Patient bundles loaded OK: <N>
Patient bundles failed:    <N>

=== Validation: resource counts on hub ===
  Patient: <N>
  Condition: <N>
  Organization: <N>
  Practitioner: <N>
```

### 3. Acceptance criteria checks (issue #7)

```bash
curl -s "http://localhost:8080/fhir/Patient?_summary=count" | python3 -m json.tool
curl -s "http://localhost:8080/fhir/Condition?_summary=count" | python3 -m json.tool
```

Expected: both return a FHIR `Bundle` with `"type": "searchset"` and a
non-zero `"total"`. For `POPULATION=100, SEED=1`, Synthea generates **113**
patient bundles (100 alive + 13 deceased — Synthea's `-p` is a target for
*living* patients at the end of the simulation, and deceased patients along
the way are also exported), all loading as `Patient` resources. A
full `POPULATION=100 SEED=1` run on the rural-TX module set produced:

| Resource | Count |
|---|---|
| `Patient` | 113 |
| `Condition` | 3472 |
| `Organization` | 402 |
| `Practitioner` | 402 |

with a meaningful share of `Diabetes mellitus type 2` and `Essential
hypertension` given Texas demographics + Synthea's default modules — these
two are the chronic-disease focus called out in `docs/adr/0001-handoff.md`.
Exact counts are seed/version-dependent but should be in this ballpark for
`SYNTHEA_VERSION=v4.0.0`.

### 4. Spot-check chronic disease prevalence

```bash
curl -s "http://localhost:8080/fhir/Condition?code=44054006&_summary=count" | python3 -m json.tool   # Diabetes mellitus type 2 (SNOMED)
curl -s "http://localhost:8080/fhir/Condition?code=59621000&_summary=count" | python3 -m json.tool   # Essential hypertension (SNOMED)
```

Expected: non-zero `"total"` for both, confirming the rural-TX population
has a representative chronic-disease burden. The `POPULATION=100 SEED=1`
run referenced above produced `8` diabetes and `20` hypertension
`Condition` resources.

## Re-running / regenerating

Because generation is seeded and reproducible:

- To **regenerate the same population**: `rm -rf synthea/output && scripts/generate-synthea.sh` (jar stays cached).
- To **wipe and reload the hub**: see `docs/runbooks/phase1-hapi-hub.md`'s
  `down -v` warning — this destroys **all** hub data, not just Synthea data.
  There's no "delete just the Synthea load" shortcut in this increment;
  Synthea-generated resource IDs aren't namespaced separately from anything
  else in the hub.
- To **load a different population size**: `POPULATION=500
  scripts/generate-synthea.sh` then `scripts/load-to-hub.sh`. Note this does
  *not* clear previously-loaded data — re-running the load script against an
  already-populated hub will create a second, larger set of resources
  (Synthea generates new UUIDs each run unless the seed AND population count
  are unchanged).

## Known limitations / what's next

- **Hub only.** Spokes (`spoke-a`, `spoke-b`) are not loaded in this
  increment — see issue #7 scope notes.
- **No de-duplication.** Re-running the full pipeline (generate + load)
  without wiping the hub will accumulate duplicate-looking patients with
  different IDs.
- **`load-to-hub.sh` validation uses `python3`** for JSON parsing
  (`_summary=count` responses) — if `python3` isn't on the host, the count
  step will print `?` but the load itself still succeeds/fails correctly.
- **Next increment:** per `docs/adr/0001-handoff.md` Phase 2, this
  population becomes the substrate for `CareTeam`, `Organization` /
  `OrganizationAffiliation` (ACO modeling), and `Subscription`-based
  encounter notifications — and eventually Mirth-routed
  hub↔spoke distribution with deliberately malformed HL7v2 to feel where
  normalization breaks.

## See also

- `docs/runbooks/phase1-hapi-hub.md` — hub/spoke compose topology and
  bring-up (prerequisite for this runbook).
- `docs/adr/0001-handoff.md` — Phase roadmap and architecture decisions.
- [FHIR R4 — Transactions](https://hl7.org/fhir/R4/http.html#transaction) —
  spec basis for the load-order requirement above.
