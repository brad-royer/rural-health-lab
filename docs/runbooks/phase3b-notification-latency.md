# Runbook: Phase 3b.4 — Verify Encounter-Notification Latency

Measures the full end-to-end CMS encounter-notification path (Gate M / ADR
0011) and records the latency lesson (Known Lessons #1). Depends on 3b.3.

## Run

```bash
python3 scripts/measure-notification-latency.py --ehr openemr   # or bahmni
```

The script (reusing the 3a.6 EHR backends) registers a patient, waits for it
to reach the HIE, creates an encounter in the participant EHR, then times:
encounter-in-EHR → (participant Mirth poll) → Encounter in HAPI → (rest-hook
Subscription) → subscriber receipt (parsed from `docker logs hie-subscriber`).
It cleans up after itself.

## Result — 2026-06-15 (PASS, OpenEMR)

```
EHR -> HIE (participant Mirth poll): 60.6 s
HIE -> subscriber (Subscription):     0.9 s
TOTAL end-to-end:                    61.5 s   (CMS SLA: 24 h = 86,400 s)
```

## The lesson (Known Lessons #1)

- **The subscription is not the bottleneck** — delivery is sub-second once the
  resource lands in HAPI. The ~60s end-to-end latency is **entirely the
  participant Mirth's poll cadence** (the encounter channel polls every 60s).
- **Latency is bounded by the weakest-cadence hop.** The CMS 24h SLA is
  trivially met; tightening real latency means reducing the poll interval or
  moving from polling to push-based ingestion (e.g., the EHR posting to Mirth,
  or atom-feed/CDC) — a cost/complexity tradeoff, not a subscription tweak.
- The genuinely hard part (3b.3) was operational config (rest-hook delivers
  via PUT; criteria needs a param; deliveries retry forever) — "subscription
  SLAs are operationally hard" is about *config and reliability*, not raw
  latency at this scale.

## Notes

No rollback needed — the script is a self-cleaning probe (deletes its test
patient/encounter in both the EHR and the HIE; the fired notification is
fire-and-forget).
