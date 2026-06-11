# Runbook: Phase 1 — HAPI FHIR Hub

## What this is

The "hub" of the lab CIN/ACO: one HAPI FHIR R4 server, backed by Postgres
for persistent storage. No spokes, integration engine, or identity provider
yet — those are later increments.

- Image: `hapiproject/hapi:v8.10.0-1` (HAPI FHIR Server 8.10.0, FHIR version
  4.0.1 / R4 — pinned explicitly so the topology doesn't silently change
  out from under you when `:latest` moves).
- Database: `postgres:16`, container `hapi-db`, named volume
  `hapi-db-data` for `/var/lib/postgresql/data`. **Data persists across
  `docker compose down` / `up`** (see "Persistence" section below).
- Compose file: `compose/docker-compose.yml`
- Secrets: `POSTGRES_PASSWORD` lives in `compose/.env` (gitignored, not
  committed). `compose/.env.example` documents the required variable —
  copy it to `compose/.env` and fill in a real value before first bring-up.

## Prerequisites

- Docker + Docker Compose plugin installed and working (`docker compose
  version`).
- Port `8080` free on the host (Postgres's `5432` is **not** published to
  the host — only `hapi-hub` talks to `db`, over the compose network).
- `compose/.env` created from `compose/.env.example` with a real
  `POSTGRES_PASSWORD` set.

## Bring-up (manual steps)

```bash
cd compose
cp -n .env.example .env   # first time only; then edit .env with a real password
docker compose up -d
```

This will:
1. Create a dedicated bridge network for the compose project (if it
   doesn't already exist).
2. Pull `postgres:16` and `hapiproject/hapi:v8.10.0-1` if not already
   cached (the HAPI image is ~1 GB — first pull can take a few minutes
   depending on connection).
3. Start `hapi-db` (Postgres), wait until it reports healthy via
   `pg_isready`, then start `hapi-hub`, publishing `8080:8080`, with
   `restart: unless-stopped` on both.

### Why `depends_on: condition: service_healthy`?

Postgres's container can accept TCP connections before it's actually ready
to serve queries (during initdb on first run). Without the healthcheck +
condition, HAPI can start, fail its first datasource connection attempt,
and either crash-loop or fall back to a broken state depending on Spring's
retry behavior. `pg_isready` plus `service_healthy` makes Compose hold
`hapi-hub`'s start until Postgres is actually accepting queries.

**Most likely failure mode:** `compose/.env` missing or
`POSTGRES_PASSWORD` unset. Compose will substitute an empty string, Postgres
will initialize with an empty/no password (or refuse, depending on image
version), and HAPI's datasource auth will fail with `password
authentication failed for user "hapi"`. Fix: ensure `compose/.env` exists
and has a non-empty `POSTGRES_PASSWORD`, then `docker compose down -v` to
wipe the bad first-run Postgres data dir and `up -d` again — **changing
`POSTGRES_PASSWORD` after the volume has initialized does NOT change the
password inside Postgres**, only `down -v` (destroying the volume) and
re-init does.

### Why no Docker HEALTHCHECK?

The `hapiproject/hapi` image is a **distroless JRE image** — there is no
shell, `curl`, or `wget` inside the container, so a conventional
`HEALTHCHECK` directive (which needs a shell command to run) isn't
practical without adding a custom image layer. That's more complexity than
this increment needs. Instead, readiness is verified externally by polling
`/fhir/metadata` (below).

**Most likely failure mode:** if you query the API immediately after
`docker compose up -d`, you'll get connection refused or a 404/empty
response — HAPI's Spring Boot startup (including building its FHIR
context and Postgres schema via Hibernate) commonly takes **30–60+
seconds** on first start, sometimes longer on a cold image pull, slow
disk, or first-run schema migration against a fresh Postgres database.
This is normal. Poll, don't assume failure on the first try.

## Validation

### 0. Confirm both containers are healthy/running

```bash
docker compose ps
```

Expected: `hapi-db` shows `(healthy)`, `hapi-hub` shows `Up`.

### 1. Poll `/fhir/metadata` until the server is ready

```bash
for i in $(seq 1 24); do
  code=$(curl -s -o /tmp/metadata.json -w "%{http_code}" http://localhost:8080/fhir/metadata)
  echo "attempt $i: HTTP $code"
  if [ "$code" = "200" ]; then break; fi
  sleep 5
done
```

This polls every 5 seconds for up to 2 minutes. Expected end state: `HTTP
200` and `/tmp/metadata.json` containing a FHIR `CapabilityStatement`.

Quick check of the body:

```bash
curl -s http://localhost:8080/fhir/metadata | python3 -c \
  "import json,sys; d=json.load(sys.stdin); print(d['resourceType'], d['fhirVersion'], d['software'])"
```

Expected output (version numbers may differ as the `:latest` tag moves):

```
CapabilityStatement 4.0.1 {'name': 'HAPI FHIR Server', 'version': '8.10.0'}
```

### 2. Create a synthetic Patient

**Synthetic data only — no real names, addresses, or identifiers.**

```bash
cat > /tmp/patient.json << 'EOF'
{
  "resourceType": "Patient",
  "name": [
    {
      "use": "official",
      "family": "Synthetic",
      "given": ["Jane", "Test"]
    }
  ],
  "gender": "female",
  "birthDate": "1990-01-01",
  "address": [
    {
      "use": "home",
      "city": "Synthetic City",
      "state": "TX",
      "postalCode": "00000",
      "country": "US"
    }
  ]
}
EOF

curl -s -X POST http://localhost:8080/fhir/Patient \
  -H "Content-Type: application/fhir+json" \
  -d @/tmp/patient.json -i
```

Expected: `HTTP/1.1 201`, with a `Location` header like
`http://localhost:8080/fhir/Patient/<id>/_history/1` and the created
resource echoed back with an assigned `id` and `meta.versionId`.

### 3. Read the Patient back

Substitute `<id>` with the id from the `Location` header (e.g. `1000`):

```bash
curl -s http://localhost:8080/fhir/Patient/<id> -H "Accept: application/fhir+json" -i
```

Expected: `HTTP/1.1 200` with the same resource body (name, gender,
birthDate, address) returned.

### Observed validation result (2026-06-10) — Phase 1.1 (H2, ephemeral)

- `GET /fhir/metadata` → `200`, `resourceType: CapabilityStatement`,
  `fhirVersion: 4.0.1`, `software: HAPI FHIR Server 8.10.0`.
- `POST /fhir/Patient` (synthetic "Jane Test Synthetic") → `201`,
  assigned `id: 1000`.
- `GET /fhir/Patient/1000` → `200`, returned resource matches what was
  created (name, gender `female`, birthDate `1990-01-01`, address in
  `Synthetic City, TX`).

## Persistence test (Phase 1.2 — Postgres)

This proves resources survive `docker compose down` (container removal)
followed by `docker compose up -d` (recreation), as long as the named
volume `hapi-db-data` is not deleted.

1. Bring the stack up, confirm `hapi-db` is healthy and `/fhir/metadata`
   returns `200` (steps 0–1 above).
2. `POST` a synthetic `Patient` (step 2 above) and note the assigned `id`
   from the `Location` header.
3. `GET /fhir/Patient/<id>` and confirm `200` with the expected body
   (step 3 above).
4. Tear the stack down **without** removing volumes:
   ```bash
   cd compose
   docker compose down
   ```
5. Bring it back up:
   ```bash
   docker compose up -d
   ```
   Wait for `/fhir/metadata` to return `200` again (step 1's poll loop —
   first start after `down`/`up` is faster than a true cold start since
   the Postgres schema already exists, but still allow the same poll
   window).
6. `GET /fhir/Patient/<id>` again with the **same id** from step 2.
   Expected: `200`, same resource body as step 3 — the Patient survived
   the container recreation because it was stored in Postgres, not in the
   removed container's filesystem.

### Observed validation result (2026-06-11) — Phase 1.2 (Postgres, persistent)

- `docker compose up -d` → `hapi-db` reported `(healthy)` (visible as
  `Container hapi-db Healthy` before `hapi-hub` started); `hapi-hub` logs
  showed `org.postgresql.jdbc.PgConnection` via HikariCP, confirming the
  Postgres datasource (not H2).
- `GET /fhir/metadata` → `200` on the first poll attempt,
  `resourceType: CapabilityStatement`, `fhirVersion: 4.0.1`,
  `software: HAPI FHIR Server 8.10.0`.
- `POST /fhir/Patient` (synthetic "Test Synthetic Persistence", family
  name "Persistence") → `201`, assigned `id: 1000`,
  `meta.versionId: 1`, `lastUpdated: 2026-06-11T04:19:24.984+00:00`.
- `docker compose down` (no `-v`) → both containers and the compose
  network removed; named volume `compose_hapi-db-data` retained
  (confirmed via `docker volume ls`).
- `docker compose up -d` → stack came back up; `/fhir/metadata` → `200`
  on the first poll attempt.
- `GET /fhir/Patient/1000` → `200`, returned the **same resource**
  (`versionId: 1`, same `lastUpdated` timestamp `2026-06-11T04:19:24.984Z`,
  same name/gender/birthDate/address) — confirms Postgres-backed
  persistence across `down`/`up`.
- Final `docker compose down` (no `-v`) left the stack stopped with
  `compose_hapi-db-data` intact (confirmed present afterward via
  `docker volume ls`) for the next session.

## Teardown

```bash
cd compose
docker compose down
```

This stops and removes the `hapi-db` and `hapi-hub` containers and the
compose network. **The named volume `hapi-db-data` is preserved** — FHIR
resources in Postgres survive this and will be there on the next
`docker compose up -d`.

### Wiping data — `down` vs `down -v`

This is the most important distinction in this runbook now that data is
persistent:

| Command | Containers/network | `hapi-db-data` volume (Postgres data) | Effect |
|---|---|---|---|
| `docker compose down` | removed | **kept** | Safe. Next `up -d` reattaches to the same Postgres data — all FHIR resources are still there. |
| `docker compose down -v` | removed | **deleted** | Destructive. Next `up -d` initializes a brand-new empty Postgres database — Postgres re-runs `initdb` using `compose/.env`'s `POSTGRES_PASSWORD`/`POSTGRES_USER`/`POSTGRES_DB`, and HAPI recreates its schema from scratch on top of that, but **all previously stored FHIR resources are gone**. |

**Most likely failure mode:** running `docker compose down -v` out of habit
(muscle memory from earlier H2-based increments where `-v` was harmless).
In this increment it permanently deletes every FHIR resource in the lab.
Treat `-v` as a deliberate "wipe the hub and start over" action — plan for
it explicitly, the same as you would `terraform destroy`.

## Known limitation / what's next

- **Single hub only.** No spokes, integration engine (Mirth), identity
  provider (Keycloak), or portal (Medplum) yet. Those are later increments
  in Phase 1/2 per `docs/adr/0001-handoff.md`.
- **Postgres port not exposed to the host.** `db` has no published port —
  only `hapi-hub` can reach it, over the compose-internal network. If you
  need to inspect the database directly (e.g. `psql`), use
  `docker compose exec db psql -U hapi -d hapi` rather than connecting from
  the host.
- **Next increment:** add spoke HAPI instances and begin Mirth Connect
  routing per the Phase 1 roadmap.
