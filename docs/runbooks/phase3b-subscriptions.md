# Runbook: Phase 3b.3 — FHIR Subscriptions + Subscriber

Stands up the CMS encounter-notification simulation (Gate M / ADR 0011): a
HAPI rest-hook `Subscription` on `Encounter` delivering to a lightweight
subscriber that timestamps receipts. The rest-hook channel was enabled in
3b.1 (MDM's dependency). Depends on 3b.1.

## Deploy

```bash
# Subscriber (built, not bind-mounted, to dodge WSL bind-mount fragility):
cd compose && docker compose up -d --build hie-subscriber
# Subscription:
curl -s -X POST http://localhost:8080/fhir/Subscription \
  -H "Content-Type: application/fhir+json" \
  -d @fhir/subscription-encounter-notification.json    # returns status active
```

- Subscriber: `compose/subscriber/` (stdlib HTTP server, logs
  `RECV <utc-ts> path=... <ResourceType>/<id>`). Reachable from HAPI at
  `http://hie-subscriber:9000` on the compose network.
- Subscription: `fhir/subscription-encounter-notification.json` — rest-hook,
  `payload: application/fhir+json`, criteria
  `Encounter?status=<all statuses>`.

## Gotchas (the Known Lessons #1 friction)

- **Rest-hook delivers via PUT**, not POST (to `<endpoint>/Encounter/<id>`).
  A POST-only receiver returns `501` and HAPI logs `HAPI-0002: Failure
  handling subscription payload` with no delivery. The receiver handles both
  (`do_PUT = do_POST`).
- **`criteria` needs a search param** — bare `"Encounter"` is rejected; use
  `Encounter?status=...`.
- Delivery failures **retry forever** on `subscription-delivery-rest-hook-<id>`
  — grep HAPI logs when nothing arrives.
- The subscriber must share HAPI's docker network (it does, `compose_default`).

## Validation (2026-06-15)

- [x] Subscription `status: active` (no `error`).
- [x] Smoke: created an Encounter in HAPI → subscriber logged
      `RECV ... /notify/Encounter/<id>` in **~4 s**. Full participant→HIE
      latency measured in 3b.4.

## Rollback

```bash
curl -s -X DELETE "http://localhost:8080/fhir/Subscription/<id>"   # stop notifications
cd compose && docker compose rm -sf hie-subscriber                 # remove subscriber
```
