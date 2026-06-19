# Runbook: Phase 3b.5 — Stand up Keycloak (realm + participant clients)

Stands up Keycloak as the HIE's identity provider with per-participant
`client_credentials` clients (Gate N / ADR 0012). HAPI-behind-OAuth and the
Mirth token wiring are 3b.6. Runs on the HIE host (Host #1).

## Deploy

```bash
cd compose && docker compose up -d keycloak     # rm -sf + up -d if a bind mount goes stale
# realm imported on first start; verify:
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8090/realms/rural-health-hie   # 200
python3 scripts/fetch_keycloak_secrets.py        # -> scripts/.secrets/keycloak-clients.json (gitignored)
```

- Keycloak 26.6.3, `start-dev --import-realm`, host port **8090** (HAPI owns
  8080). Realm `compose/keycloak/realm-export.json` mounted into
  `/opt/keycloak/data/import`; `keycloak-data` volume persists the
  Keycloak-generated client secrets across restarts.
- Clients: `central-hospital-mirth`, `acquired-cah-mirth` — confidential,
  `serviceAccountsEnabled` (client_credentials), no committed secrets.

## Gotchas / version notes (Keycloak 26)

- Bootstrap admin env is **`KC_BOOTSTRAP_ADMIN_USERNAME` /
  `KC_BOOTSTRAP_ADMIN_PASSWORD`** (the old `KEYCLOAK_ADMIN*` were removed in
  26). Password from gitignored `.env` `KEYCLOAK_ADMIN_PASSWORD` (defaults to
  `admin` for the lab — change before production-like use).
- Realm import dir is `/opt/keycloak/data/import` with `--import-realm`;
  re-import is skipped if the realm already exists in the data volume (so
  secrets stay stable — verified surviving a full host reboot).
- Secrets aren't committed; re-run `fetch_keycloak_secrets.py` only if the
  `keycloak-data` volume is wiped (secrets regenerate on a fresh import).

## Validation (2026-06-15)

- [x] Realm `rural-health-hie` imported; `/realms/rural-health-hie` → 200.
- [x] Both clients present; secrets fetched to `scripts/.secrets/`.
- [x] Smoke: `client_credentials` token mints for `acquired-cah-mirth`
      (`iss=…/realms/rural-health-hie`, `azp=acquired-cah-mirth`, 300s).

## Cross-host note (for 3b.6)

The token `iss` is a URL; for the CAH Mirth (Host #2) to obtain tokens and
HAPI to validate them, the issuer must be consistent across hosts — 3b.6 sets
`KC_HOSTNAME`/frontend URL and exposes Keycloak to the LAN (like the HAPI
portproxy) so all parties agree on one issuer.

## Rollback

```bash
cd compose && docker compose rm -sf keycloak
docker volume rm compose_keycloak-data     # also drops the realm + secrets
```
