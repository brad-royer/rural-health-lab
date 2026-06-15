# Runbook: Phase 3b.1 — Enable HAPI MDM + Matching Rules

Enables HAPI's built-in MDM (link-not-merge) on the HIE per Gate L (ADR 0010),
so 3b.2 can link the three-way duplicate cohort. **Reconfigures + restarts the
live HAPI** — plan/confirm.

## Config approach

The `hapiproject/hapi:v8.10.0-1` image is distroless (no shell) and is
configured via env vars + an optional overlay `application.yaml`. This
increment adds an overlay rather than rewriting config:

- `compose/hapi-config/application.yaml` — enables `mdm_enabled`,
  `subscription.resthook_enabled` (MDM's dependency), and points
  `mdm_rules_json_location` at the mounted rules file.
- `compose/hapi-config/mdm-rules.json` — the Gate L matching rules.
- `compose/docker-compose.yml` (hapi-hub): mounts `./hapi-config:/configs:ro`
  and sets `SPRING_CONFIG_ADDITIONAL_LOCATION=file:///configs/application.yaml`
  (layered onto the starter defaults; the Postgres password stays in env, not
  in the committed YAML).

Apply: `docker compose up -d hapi-hub` (recreates), then poll
`http://localhost:8080/fhir/metadata` for 200.

## Gotchas (measured 2026-06-15)

- **`mdm_rules_json_location` is a Spring ResourceLoader location.** An
  unprefixed/absolute path (`/configs/mdm-rules.json`) is read as a
  **classpath** resource (`class path resource [configs/mdm-rules.json] ...
  does not exist`) and **crash-loops HAPI**. Use the `file:` prefix:
  `file:/configs/mdm-rules.json`. A bad MDM config fails HAPI startup
  entirely — validate before relying on it.
- **MDM requires subscriptions** — `subscription.resthook_enabled: true` is
  mandatory or the MDM beans fail to wire.
- **No auto-linking of existing data.** The participant channels re-`PUT`
  identical content (no-op updates don't bump the version → no MDM trigger),
  and Synthea is static, so enabling MDM creates **zero** golden records on
  its own. 3b.2 forces linkage with `$mdm-submit`.

## Validation (2026-06-15)

- [x] HAPI back up (metadata 200) after the MDM restart; 144 patients intact
      (113 Synthea + 16 bahmni-central + 15 openemr-cah).
- [x] MDM active: `GET /fhir/$mdm-query-links` → 200 (operation only present
      when MDM is enabled); 0 links / 0 golden records yet (expected).
- [x] Both participant Mirths recovered after the restart and resumed writing
      (idempotent pollers; brief gap, no data loss).

## Rollback

Remove the overlay env + volume from the `hapi-hub` service (or set
`mdm_enabled: false` in `application.yaml`) and `docker compose up -d
hapi-hub`. Since 3b.1 creates no golden records, there's nothing to clean up;
if 3b.2 has run, also clear MDM links/golden records first
(`$mdm-clear` per resource type).
