# Runbook: Phase 1.1 — Single HAPI FHIR Hub (Walking Skeleton)

## What this is

The smallest possible "hub": one HAPI FHIR R4 server, no database, no
spokes, no integration engine, no identity provider. The goal is to prove
the basic Docker Compose + FHIR REST loop works before adding complexity.

- Image: `hapiproject/hapi:latest` (currently resolves to HAPI FHIR Server
  8.10.0, FHIR version 4.0.1 / R4 — this is the image's default FHIR
  version, no extra config needed for R4).
- Storage: **in-memory H2** (the image default). No volume is mounted.
  Data is lost whenever the container is stopped/removed.
- Compose file: `compose/docker-compose.yml`

## Prerequisites

- Docker + Docker Compose plugin installed and working (`docker compose
  version`).
- Port `8080` free on the host.

## Bring-up (manual steps)

```bash
cd compose
docker compose up -d
```

This will:
1. Create a dedicated bridge network for the compose project (if it
   doesn't already exist).
2. Pull `hapiproject/hapi:latest` if not already cached (~1.5 GB image —
   first pull can take a few minutes depending on connection).
3. Start a single container named `hapi-hub`, publishing `8080:8080`,
   with `restart: unless-stopped`.

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
context and H2 schema) commonly takes **30–60+ seconds** on first start,
sometimes longer on a cold image pull or slow disk. This is normal. Poll,
don't assume failure on the first try.

## Validation

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

### Observed validation result (2026-06-10)

- `GET /fhir/metadata` → `200`, `resourceType: CapabilityStatement`,
  `fhirVersion: 4.0.1`, `software: HAPI FHIR Server 8.10.0`.
- `POST /fhir/Patient` (synthetic "Jane Test Synthetic") → `201`,
  assigned `id: 1000`.
- `GET /fhir/Patient/1000` → `200`, returned resource matches what was
  created (name, gender `female`, birthDate `1990-01-01`, address in
  `Synthetic City, TX`).

## Teardown

```bash
cd compose
docker compose down
```

This stops and removes the `hapi-hub` container and the compose network.

### Wiping data

There is **no volume** in this increment, so data is already as ephemeral
as it gets:

- `docker compose down` (or even `docker compose restart hapi-hub`) is
  enough to wipe all FHIR resources — the in-memory H2 database is
  recreated empty on next start.
- `docker compose down -v` would also work but there's no named volume to
  remove yet, so it's equivalent to plain `down` here.

## Known limitation / what's next

- **Data is ephemeral.** The image defaults to an in-memory H2 database
  with no volume mount. Every restart starts from a blank FHIR store.
  This is intentional for this walking-skeleton increment — the goal was
  to prove the container + REST loop, not durability.
- **Next increment:** add a Postgres service and configure HAPI to use it
  (via `hapi.fhir.persistence` JPA datasource env vars), with a named
  Docker volume for the Postgres data directory, so resources survive
  container recreation.
