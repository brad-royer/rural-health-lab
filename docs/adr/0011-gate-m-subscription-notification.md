# ADR 0011 - Gate M: Subscription Mechanism & Subscriber

## Status
Accepted - 2026-06-15

## Context
Phase 3b (`docs/phase3b-kickoff-prompt.md`, Gate M) simulates the CMS
"encounter notification within 24 hours" requirement with FHIR Subscriptions
(handoff: `Subscription` resources model this; Known Lessons #1: subscription
SLAs are operationally hard - feel the latency/config pain). The subscription
channel is already enabled (rest-hook, turned on as MDM's dependency in 3b.1).

## Decision
1. **HAPI rest-hook `Subscription` on `Encounter`** (`fhir/subscription-
   encounter-notification.json`), `payload: application/fhir+json` so the
   Encounter is delivered, not just a ping.
2. **Subscriber: a lightweight in-network webhook receiver**
   (`compose/subscriber/`, service `hie-subscriber`) that timestamps each
   delivery to stdout, so latency is measurable from `docker logs`. Reachable
   from HAPI on the compose network at `http://hie-subscriber:9000`.
3. **"Within 24h" = simulate + measure, not enforce.** The lab delivers in
   seconds (~4s smoke); the point is to exercise the mechanism and feel the
   config friction, not build SLA enforcement/alerting.

## Gotchas (measured 2026-06-15)
- **Rest-hook with a payload delivers via HTTP `PUT`** (RESTful update style,
  to `<endpoint>/<ResourceType>/<id>`), not POST. A receiver that only handles
  POST returns `501 Unsupported method ('PUT')` and HAPI logs `HAPI-0002:
  Failure handling subscription payload` - silently, with no delivery. The
  receiver must accept PUT.
- **Subscription `criteria` requires a search parameter** - bare `"Encounter"`
  is rejected by HAPI's subscription validation; use e.g.
  `Encounter?status=...` (a comprehensive status list matches all encounters).
- Delivery failures retry indefinitely on the subscription channel - watch
  HAPI logs for `subscription-delivery-rest-hook-<id>` errors.

## Consequences
- 3b.4 measures end-to-end latency (participant EHR -> Mirth -> HAPI ->
  Subscription -> subscriber) against the simulated SLA.
- The subscription fires on every matching Encounter create/update; the
  participant channels' no-op re-upserts don't bump versions, so they don't
  spam it - only genuinely new/changed encounters notify.
- **Production delta:** a real subscriber has authentication, persistence,
  retry/dead-letter handling, and the HIE has SLA monitoring/alerting; this
  receiver has none (it's a latency probe).

## Related
- `docs/phase3b-kickoff-prompt.md` - Gate M
- Known Lessons #1 - `docs/adr/0001-handoff.md`
- `fhir/subscription-encounter-notification.json`,
  `compose/subscriber/`, `docs/runbooks/phase3b-subscriptions.md`
- Increment 3b.3 (#45); latency verification in 3b.4 (#46)
