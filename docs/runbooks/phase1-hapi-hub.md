# Runbook: Phase 1 — HAPI FHIR Hub + Spokes

## What this is

The local core of the lab CIN/ACO:

- **Hub** (`hapi-hub`): one HAPI FHIR R4 server, backed by Postgres for
  persistent storage.
- **Spokes** (`spoke-a`, `spoke-b`): two lightweight HAPI FHIR R4 servers
  simulating partner EMRs (e.g. an RHC and an FQHC), each with its own
  ephemeral in-memory H2 database.

No integration engine (Mirth) or identity provider (Keycloak) yet — those
are later increments per `docs/adr/0001-handoff.md`.

### Topology

| Service | Container | Image | Storage | Host port → container port |
|---|---|---|---|---|
| Hub | `hapi-hub` | `hapiproject/hapi:v8.10.0-1` | Postgres (`hapi-db`, persistent) | `8080:8080` |
| DB | `hapi-db` | `postgres:16` | named volume `hapi-db-data` | not published to host |
| Spoke A | `spoke-a` | `hapiproject/hapi:v8.10.0-1` | in-memory H2 (ephemeral) | `8081:8080` |
| Spoke B | `spoke-b` | `hapiproject/hapi:v8.10.0-1` | in-memory H2 (ephemeral) | `8082:8080` |

- Image: `hapiproject/hapi:v8.10.0-1` (HAPI FHIR Server 8.10.0, FHIR version
  4.0.1 / R4 — pinned explicitly so the topology doesn't silently change
  out from under you when `:latest` moves). All three FHIR servers (hub +
  2 spokes) use this same pinned image.
- Database: `postgres:16`, container `hapi-db`, named volume
  `hapi-db-data` for `/var/lib/postgresql/data`. **Only the hub uses
  Postgres. Data persists across `docker compose down` / `up`** (see
  "Persistence" section below).
- Spokes (`spoke-a`, `spoke-b`) use HAPI's **default in-memory H2** — no
  datasource env vars, no volume. Any Patient/resource data created on a
  spoke is **lost on container recreation** (`down`/`up`, or any time the
  container restarts and re-initializes H2). This is intentional for this
  increment: spokes are placeholders for "some other org's FHIR endpoint,"
  not systems we need to persist yet.
- Compose file: `compose/docker-compose.yml`
- Secrets: `POSTGRES_PASSWORD` lives in `compose/.env` (gitignored, not
  committed). `compose/.env.example` documents the required variable —
  copy it to `compose/.env` and fill in a real value before first bring-up.

### Why host port != container port for the spokes

All three HAPI containers listen on **8080 internally** — that's the fixed
default baked into the `hapiproject/hapi` image (it's a Spring Boot app
with `server.port=8080`, and changing it would require an extra env var on
top of everything else). You can't publish three containers to the same
host port `8080:8080` simultaneously — the host only has one `8080`, and
Docker would refuse to bind it twice.

So the **host-side** port is what makes each service distinguishable from
your workstation:

- `8080:8080` → hub, internal `8080` → host `8080`
- `8081:8080` → spoke-a, internal `8080` → host `8081`
- `8082:8080` → spoke-b, internal `8080` → host `8082`

Inside the compose network, containers always talk to each other on the
**container port** using the **service name** as hostname — e.g. a future
Mirth channel would call `http://spoke-a:8080/fhir/...`, never
`http://spoke-a:8081/...`. The host-port mapping (`8081`, `8082`) only
matters for connections originating from outside the compose network (your
browser, `curl` from WSL2, etc.).

**Most likely failure mode:** assuming the container port changes when you
change the host port. Editing `"8081:8080"` to `"9000:8080"` only changes
how you reach the container *from the host* — internal compose-network
traffic to `spoke-a:8080` is unaffected. Conversely, if you see "port is
already allocated" on `docker compose up`, it's almost always a **host**
port collision (something else on your WSL2/Windows host already bound
that port), not a container-port conflict.

## Prerequisites

- Docker + Docker Compose plugin installed and working (`docker compose
  version`).
- Ports `8080`, `8081`, `8082` free on the host (Postgres's `5432` is
  **not** published to the host — only `hapi-hub` talks to `db`, over the
  compose network).
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
   depending on connection; the same image is reused for the hub and both
   spokes, so it's only pulled once).
3. Start `hapi-db` (Postgres), wait until it reports healthy via
   `pg_isready`, then start `hapi-hub`, publishing `8080:8080`, with
   `restart: unless-stopped`.
4. Start `spoke-a` (publishing `8081:8080`) and `spoke-b` (publishing
   `8082:8080`) in parallel — they have no dependency on `db` or
   `hapi-hub`, so they don't wait for the hub's healthcheck.

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

### 0. Confirm all four containers are healthy/running

```bash
docker compose ps
```

Expected: `hapi-db` shows `(healthy)`, `hapi-hub`, `spoke-a`, `spoke-b` all
show `Up`.

### 1. Poll `/fhir/metadata` on all three FHIR servers until ready

```bash
for port in 8080 8081 8082; do
  echo "=== Polling port $port ==="
  for i in $(seq 1 24); do
    code=$(curl -s -o /tmp/metadata_$port.json -w "%{http_code}" http://localhost:$port/fhir/metadata)
    echo "attempt $i: HTTP $code"
    if [ "$code" = "200" ]; then break; fi
    sleep 5
  done
done
```

This polls each of `8080` (hub), `8081` (spoke-a), `8082` (spoke-b) every
5 seconds for up to 2 minutes. Expected end state: `HTTP 200` for all
three, with `/tmp/metadata_<port>.json` containing a FHIR
`CapabilityStatement`.

Quick check of each body:

```bash
for port in 8080 8081 8082; do
  echo "=== port $port ==="
  python3 -c "import json; d=json.load(open('/tmp/metadata_$port.json')); print(d['resourceType'], d['fhirVersion'], d['software'])"
done
```

Expected output for each (version numbers may differ as the `:latest` tag
moves — but all three should match, since they're the same pinned image):

```
CapabilityStatement 4.0.1 {'name': 'HAPI FHIR Server', 'version': '8.10.0'}
```

### 1a. Verify internal DNS resolution of spoke-a / spoke-b

The acceptance criteria call for confirming that `spoke-a` and `spoke-b`
resolve by **service name** on the compose network — this is how Mirth (a
later increment) and the hub will eventually address each spoke, instead
of hardcoded IPs.

`hapi-hub`'s image (`hapiproject/hapi`) is **distroless** — there is no
shell (`sh`), so `docker compose exec hapi-hub getent hosts spoke-a`
fails with `exec: "sh": executable file not found in $PATH`. Instead,
attach a throwaway container with a shell to the same compose network and
query Docker's embedded DNS (`127.0.0.11`), which is the exact resolver
every container on this network uses:

```bash
docker run --rm --network compose_default busybox:1.36 sh -c \
  "nslookup spoke-a; echo ---; nslookup spoke-b; echo ---; nslookup hapi-hub; echo ---; nslookup db"
```

Expected: each `nslookup` returns a `Non-authoritative answer` with a
`Name:` matching the service and an `Address:` in the compose network's
subnet (e.g. `172.18.0.0/16`) — confirming `spoke-a`, `spoke-b`,
`hapi-hub`, and `db` are all resolvable by name on `compose_default`.

**Most likely failure mode:** the network name. Compose derives the
network name from the **directory name** the compose file lives in (here,
`compose`), giving `compose_default` — if you renamed the directory or
ran `docker compose -p <other-name>`, the network will be
`<other-name>_default` instead, and `docker run --network compose_default
...` will fail with "network not found." Run `docker network ls` to find
the actual name if this happens.

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

## Validation (Phase 1.3 — spokes)

### Observed validation result (2026-06-11) — Phase 1.3 (hub + spoke-a + spoke-b)

- `docker compose up -d` → 4 containers created on a new `compose_default`
  network: `hapi-db`, `hapi-hub`, `spoke-a`, `spoke-b`. `hapi-db` reported
  `Healthy` before `hapi-hub` started, as expected; `spoke-a`/`spoke-b`
  started immediately in parallel (no `depends_on`).
- `GET /fhir/metadata`:
  - port `8080` (hub): attempt 1 → `HTTP 000` (connection refused — still
    starting), attempt 2 (5s later) → `HTTP 200`.
  - port `8081` (spoke-a): attempt 1 → `HTTP 200`.
  - port `8082` (spoke-b): attempt 1 → `HTTP 200`.
  - All three bodies: `CapabilityStatement 4.0.1 {'name': 'HAPI FHIR
    Server', 'version': '8.10.0'}` — confirms hub and both spokes are
    running the same pinned image/version.
- Internal DNS check via `docker run --rm --network compose_default
  busybox:1.36 sh -c "nslookup spoke-a; nslookup spoke-b; nslookup
  hapi-hub; nslookup db"`:
  - `spoke-a` → `172.18.0.3`
  - `spoke-b` → `172.18.0.2`
  - `hapi-hub` → `172.18.0.5`
  - `db` → `172.18.0.4`
  - All four resolved via Docker's embedded DNS (`127.0.0.11`) on
    `compose_default`, confirming service-name resolution works for the
    spokes (and everything else) on the compose network.
- `docker compose down` (no `-v`) → all 4 containers and the
  `compose_default` network removed cleanly; `compose_hapi-db-data`
  volume confirmed still present via `docker volume ls` afterward.

## Teardown

```bash
cd compose
docker compose down
```

This stops and removes the `hapi-db`, `hapi-hub`, `spoke-a`, and `spoke-b`
containers and the compose network. **The named volume `hapi-db-data` is
preserved** — FHIR resources in Postgres (the hub) survive this and will
be there on the next `docker compose up -d`. **Anything created on
`spoke-a` or `spoke-b` is lost** — they use ephemeral in-memory H2 with no
volume, so each `down`/`up` cycle gives them a fresh, empty database
regardless of `-v`.

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

- **Hub + 2 spokes, no routing yet.** No integration engine (Mirth),
  identity provider (Keycloak), or portal (Medplum) yet. Those are later
  increments in Phase 1/2 per `docs/adr/0001-handoff.md`.
- **Spokes are ephemeral.** `spoke-a`/`spoke-b` use in-memory H2 — any
  data created on them is lost on container recreation. This is
  intentional for now; revisit if a later increment needs spoke data to
  survive restarts (would mirror the hub's Postgres pattern, one DB per
  spoke or a shared multi-schema DB).
- **Postgres port not exposed to the host.** `db` has no published port —
  only `hapi-hub` can reach it, over the compose-internal network. If you
  need to inspect the database directly (e.g. `psql`), use
  `docker compose exec db psql -U hapi -d hapi` rather than connecting from
  the host.
- **Next increment:** Synthea synthetic population data and/or begin
  Mirth Connect routing between hub and spokes per the Phase 1 roadmap.
  See `docs/runbooks/phase1-synthea.md` for generating and loading a
  synthetic rural-TX population (Phase 1.4, issue #7).
