# ADR 0012 - Gate N: Keycloak / OAuth Scope

## Status
Accepted - 2026-06-15

## Context
Phase 3b (`docs/phase3b-kickoff-prompt.md`, Gate N) introduces Keycloak to
retire the standing production delta: participants currently write to HAPI
**unauthenticated** (only a subnet firewall rule gates them). Gate N fixes
what Keycloak secures and how deep to model identity assurance (Known Lessons
#2: IAL2/AAL2 identity is a real integration project; later -> ID.me, Phase 5).

## Decision
1. **Keycloak secures the HIE write boundary first.** Each participant gets an
   OAuth2 **`client_credentials`** client in the `rural-health-hie` realm
   (`central-hospital-mirth`, `acquired-cah-mirth`); in 3b.6 HAPI validates the
   issued JWTs and both Mirths present tokens on their writes. This is the
   machine-to-machine layer - the direct production-delta item.
2. **Client secrets are Keycloak-generated, not committed.** The realm export
   (`compose/keycloak/realm-export.json`) defines the clients with no secrets;
   `scripts/fetch_keycloak_secrets.py` reads the generated secrets into
   `scripts/.secrets/keycloak-clients.json` (gitignored, Hard Rule #6). A
   persisted Keycloak data volume keeps them stable across restarts.
3. **IAL2/AAL2 is modeled conceptually, not enforced.** The realm + OAuth
   client layer is the learning surface; human IAL2/AAL2 step-up authenticators
   and any human/portal OIDC flow are an explicit **stretch/later** (and the
   ID.me bridge is Phase 5). 3b stays on the participant->HIE machine boundary.
4. **Keycloak 26.6.3, dev mode + realm import**, on the HIE host (Host #1),
   host port 8090 (HAPI owns 8080).

## Cross-host issuer consideration (binds 3b.6)
The token `iss` is a URL (`http://localhost:8090/realms/rural-health-hie` from
the HIE host). For the boundary to work across hosts, the **issuer must be
consistent** between token issuance (the CAH Mirth on Host #2 reaching Keycloak
over the LAN) and validation (HAPI reaching Keycloak on the compose network).
3b.6 resolves this with `KC_HOSTNAME`/frontend-URL config + LAN exposure of
Keycloak (mirroring the HAPI portproxy), so all parties agree on one issuer.

## Consequences
- 3b.6 configures HAPI's OAuth/JWT validation against the realm JWKS and
  updates both Mirth channels to fetch + present `client_credentials` tokens;
  unauthenticated writes are then rejected and `verify-onboarding.py` re-run
  for both EHRs against the authenticated HAPI.
- **Production delta:** dev-mode Keycloak (embedded H2), `admin`/`admin`
  bootstrap default (overridable via gitignored `.env`
  `KEYCLOAK_ADMIN_PASSWORD`), and plain HTTP - production wants prod mode +
  external DB + CA TLS + secret rotation, and real IAL2/AAL2 human flows.

## Related
- `docs/phase3b-kickoff-prompt.md` - Gate N; Known Lessons #2
- `compose/keycloak/realm-export.json`, `scripts/fetch_keycloak_secrets.py`
- `docs/runbooks/phase3b-keycloak.md`
- Increment 3b.5 (#47); HAPI-behind-OAuth + re-verify in 3b.6 (#48)
