# Runbook: Phase 3a.5 — CAH Mirth + Channels (OpenEMR → HIE, Federation A1)

Stands up the acquired CAH's own Mirth on Host #2 and the channels that
onboard OpenEMR to the HIE — per Gate K (ADR 0009), federation A1, across the
cross-host boundary (Gate J / ADR 0006). Second worked example of the "wire
the participant into the HIE" template step. Depends on 3a.3/3a.4 + the
cross-host networking (3a.1).

## Architecture

```
OpenEMR (rhl-acquired-cah VM, Host #2)
  FHIR R4 API  <-- poll every 60s, SMART Backend Services OAuth
        |          (client_credentials + private_key_jwt, signed in-channel)
  CAH Mirth 4.5.2 ("cah-mirth" container, same VM)  [one Mirth per org, A1]
        |  transform: strip OpenEMR internals, stamp openemr-cah system URI
        v
  HIE HAPI (Host #1, 192.168.1.176:8080)  <-- ACROSS the cross-host boundary
        conditional PUT keyed on identifier (upsert; HAPI assigns ids)
```

- Patient key: `https://lab.example/identifiers/openemr-cah|<CAH-NNNN>`
- Encounter key: `.../openemr-cah/encounter|<OpenEMR encounter uuid>`, subject
  resolved by identifier search in HAPI (never hardcoded ids).

## Prerequisites

- OpenEMR up with the seed panel + OAuth client enabled (3a.3/3a.4).
- HAPI exposed to the LAN (`Expose-HAPI-ToLAN.ps1`, Gate J).
- The CAH's OAuth client private key staged on the VM at
  `~/cah-mirth/secrets/openemr-client-key.pem` (gitignored; from
  `scripts/openemr_oauth.py register`).

## Deploy

```bash
# Mirth (on the VM):
scp -i <key> compose/cah-mirth/docker-compose.yml ubuntu@192.168.1.189:~/cah-mirth/
ssh -i <key> ubuntu@192.168.1.189 'cd ~/cah-mirth && docker compose up -d'
# Channels (from the control plane, targets https://192.168.1.189:8443):
scripts/deploy-cah-mirth-channels.sh
```

- Mirth pinned `nextgenhealthcare/connect:4.5.2` (ADR 0005), embedded Derby,
  admin/API on 8443 (OpenEMR owns 80/443 on the VM). The key is mounted
  read-only at `/opt/connect/openemr-client-key.pem`.
- The deploy script is idempotent (PUT override + redeploy).

## Validation (2026-06-14)

- [x] CAH Mirth API reachable from the control plane at
      `https://192.168.1.189:8443`.
- [x] Patient channel: 15 OpenEMR patients upserted into HAPI under
      `openemr-cah`, 0 errors; idempotent (each poll re-fetches ~30 across
      OpenEMR's 2 pages → 15 unique via conditional upsert).
- [x] Three-way duplicate live (ADR 0008): e.g. Anita473 Díaz674 in HAPI as
      Synthea + `bahmni-central|BAH-0005` + `openemr-cah|CAH-0005`.
- [x] HIE Synthea (113) + Bahmni (16) populations unchanged (additive only).
- [ ] Encounter channel: deployed, `received=0` (no OpenEMR encounters yet);
      fully validated in 3a.6 when verification creates one.

## Channel design notes / gotchas

1. **OAuth in Rhino.** The channel signs an RS384 JWT client-assertion with
   `java.security` (load PKCS8 key → `Signature.SHA384withRSA`), exchanges it
   at OpenEMR's token endpoint, then calls FHIR. No password grant exists
   (ADR 0009). Apache HttpClient throughout (Java 17 / Rhino — ADR 0005).
2. **Private key handling.** Mounted read-only into the container, CAH-host-
   local, gitignored — never in the committed XML. Real per-participant
   secret management (production: secrets manager / mTLS).
3. **Identifier mapping.** OpenEMR exposes the CAH MRN as `pubpid` under the
   generic `v2-0203` "PT" system; the transform reads that value and stamps
   the `openemr-cah` participant URI HIE-side.
4. **Encounter-before-patient race.** Same terminal-error hazard as 2.5
   (Mirth's destination retry doesn't re-run JS Writer throws); the encounter
   channel waits in-channel up to 90s for the subject before failing.
5. **Known limitation — non-incremental polling.** The patient channel
   re-polls the full Patient set each cycle (no `_lastUpdated` filter, unlike
   the Bahmni channel), re-upserting every minute. Harmless (idempotent) but
   inflates the Mirth message store; add incremental polling before any
   volume.

## Production delta (carried into 3b)

The CAH Mirth writes to HAPI **unauthenticated** (HAPI has no auth; the only
gate is the subnet-scoped firewall rule). HIE-boundary OAuth — each
participant authenticating to the HIE — arrives with Keycloak in Phase 3b.
Note this is *different* from the source-side OAuth above (OpenEMR → Mirth),
which is internal to the CAH and is done.

## Rollback

```bash
# Channels: undeploy
for id in 97f2eadd-61a6-4098-a74e-4910cd9c181e 1c8777ff-709b-48e7-a87c-070a20ae27d5; do
  curl -sk -u admin:admin -H "X-Requested-With: OpenAPI" -X POST \
    "https://192.168.1.189:8443/api/channels/$id/_undeploy"
done
# Whole CAH Mirth: ssh ... 'cd ~/cah-mirth && docker compose down [-v]'
# HIE-side cleanup of synced resources (never touches Synthea/Bahmni):
curl -s -X DELETE "http://localhost:8080/fhir/Encounter?identifier=https%3A%2F%2Flab.example%2Fidentifiers%2Fopenemr-cah%2Fencounter%7C&_cascade=delete"
curl -s -X DELETE "http://localhost:8080/fhir/Patient?identifier=https%3A%2F%2Flab.example%2Fidentifiers%2Fopenemr-cah%7C"
```
