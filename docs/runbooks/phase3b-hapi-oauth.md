# Runbook: Phase 3b.6 — HIE Behind OAuth (Both Participants Authenticated)

Puts the HIE write boundary behind OAuth so participants authenticate to it
(Gate N / ADR 0012), retiring the standing production delta. Depends on 3b.5
(Keycloak + clients). The invasive increment — Hard Rule #1: the federation
keeps working, re-verified.

## Architecture

```
participant Mirth --(client_credentials token from Keycloak)-->
  HIE OAuth gateway (validates JWT: sig via realm JWKS, iss, exp)
    --> HAPI (hapi-hub:8080, internal)
```

- **Gateway** (`compose/hie-gateway/`): JWT-validating reverse proxy, host
  port **8085** (8080/8081/8082/8443/8090 were taken). Stock HAPI has no
  turnkey OAuth, so this is the enforcement point.
- **Issuer**: `KC_HOSTNAME=http://192.168.1.176:8090` pins every token's `iss`
  to the LAN URL, so both participants (central via the compose net, CAH via
  the LAN) get a consistent issuer the gateway validates. JWKS is fetched
  internally (`http://keycloak:8080/...`), decoupled from the `iss` check.
- **Boundary** (`Expose-HIE-Boundary.ps1`, elevated on Host #1): LAN `:8080`
  → gateway (`:8085`); Keycloak exposed on LAN `:8090`. HAPI's own `:8080`
  stays internal (control-plane reads).
- **Both Mirths** fetch a `client_credentials` token (secret mounted,
  gitignored) and present `Bearer` on every HAPI call; the Bahmni (HIE) Mirth
  now writes to `hie-gateway:8080`, the CAH Mirth to `192.168.1.176:8080`
  (→ gateway).

## Deploy

```bash
cd compose && docker compose up -d --build hie-gateway     # gateway
# Keycloak KC_HOSTNAME already set in compose; recreate if changed.
# (Host #1, elevated) re-point the boundary:
#   infra/hyperv/Expose-HIE-Boundary.ps1
scripts/deploy-mirth-channels.sh          # HIE Mirth (Bahmni) channels
scripts/deploy-cah-mirth-channels.sh      # CAH Mirth (OpenEMR) channels
```

## Gotchas

- **Gateway port**: 8085 — 8080/8081/8082 are HAPI + the two spokes, 8443
  Mirth, 8090 Keycloak. Binding 8081 silently hit spoke-a (always 200).
- **Rest-hook/JWT**: the gateway validates RS256 with `cryptography` (no
  PyJWT), refreshing JWKS on unknown `kid`.
- **Order of cutover**: deploy the Bahmni channels (gateway+Keycloak reachable
  internally) *before* the boundary re-point; the CAH channels *after* it
  (they need LAN Keycloak `:8090`). Brief CAH 401 gap between the re-point and
  the CAH redeploy — idempotent pollers recover.
- **Reboot/VM recovery**: re-run `Expose-HIE-Boundary.ps1` after a reboot
  (volatile WSL IP); Host #2's OpenEMR VM may be Off — start via WinRM
  (`Start-VM rhl-acquired-cah`) and find its lease via the neighbor cache.

## Validation (2026-06-20, PASS)

- [x] Gateway: no token → 401, bogus token → 401, valid token → 200 (proxied).
- [x] Central participant authenticated: Bahmni Mirth writes 16 patients +
      encounters through the gateway (token from Keycloak), patient channel
      error=0.
- [x] CAH participant authenticated: OpenEMR Mirth writes via the LAN gateway
      with a token (15 openemr-cah patients present, encounter channel error=0).
- [x] `verify-onboarding.py` PASSes for **both** `--ehr bahmni` and
      `--ehr openemr` against the authenticated boundary — patient + encounter
      round trip, subject resolved, Synthea/populations unchanged, clean
      teardown.
- [x] Unauthenticated LAN write rejected: `GET 192.168.1.176:8080/fhir/...`
      without a token → **401**; with a token → 200.

> Note: the CAH patient channel shows a large cumulative error count — these
> are historical (the 401s during the boundary-cutover gap before the CAH
> channels were redeployed, plus the VM-down periods, compounded by
> non-incremental re-polling, ADR 0009). Current authenticated writes are
> clean (no recent errors; both verifies PASS).

## Production delta

The gateway is a minimal validator (no audience/scope checks, no rate lim 
limiting, no mTLS); Keycloak is dev-mode/HTTP. Production wants
audience-scoped tokens, TLS everywhere, and a hardened gateway/API manager.
HIE-boundary OAuth is now in place — the standing 3a delta is retired.
