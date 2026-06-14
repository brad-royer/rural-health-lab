# ADR 0009 - Gate K: OpenEMR Integration Source and Direction

## Status
Accepted - 2026-06-14

## Context
Phase 3a (`docs/phase3a-kickoff-prompt.md`, Gate K) needs patient/encounter
events to flow out of OpenEMR (the acquired CAH's EHR, Host #2) into the CIN
HIE (HAPI, Host #1), via the CAH's own Mirth (federation A1). Gate K is the
OpenEMR analog of Gate C (ADR 0005, Bahmni): which source mechanism, which
direction, and how does it differ from Bahmni now that we know OpenEMR
firsthand (3a.3/3a.4).

## Decision
1. **Source: poll OpenEMR's FHIR R4 API** (`/apis/default/fhir/Patient`,
   `/Encounter`), authenticated with **SMART Backend Services OAuth**
   (`client_credentials` + `private_key_jwt`). Outbound only; inbound stays
   a stretch goal not started.
2. **Sink: conditional upsert into the HIE's HAPI**, keyed on identifier -
   `Patient?identifier=https://lab.example/identifiers/openemr-cah|<MRN>` and
   `Encounter?identifier=.../openemr-cah/encounter|<OpenEMR encounter uuid>`.
   HAPI ids never set; encounter subjects resolved by identifier search.
3. **Direction/topology: federation A1** - the CAH's Mirth (Host #2) writes
   to HAPI **directly across the cross-host boundary** (Host #1
   `192.168.1.176:8080`, exposed per Gate J / ADR 0006). One Mirth per org
   (Known Lessons #9); it does not route through the central hospital's Mirth
   and does not straddle orgs.
4. **Engine: Mirth Connect 4.5.2** (the CAH's own instance,
   `compose/cah-mirth/`), channels committed in
   `compose/cah-mirth/channels/`.

## How OpenEMR differs from Bahmni (the "unlike case" 3a set out to find)
- **OAuth, not basic auth.** Bahmni's FHIR2 took basic auth; OpenEMR's FHIR
  is SMART/OAuth2-gated with no password grant. The channel signs an RS384
  JWT client-assertion **in Rhino via `java.security`** (load PKCS8 key,
  `Signature.SHA384withRSA`), exchanges it for a bearer token, then calls
  FHIR - all in-channel. The client's private key is mounted read-only into
  the CAH Mirth container (CAH-host-local, gitignored), never in the XML.
- **API disabled by default** (`rest_fhir_api` / `rest_api` /
  `rest_system_scopes_api` globals) and **clients disabled until enabled** -
  prerequisites, not channel concerns, but part of onboarding OpenEMR (ADR
  0008 / `phase3a-seed-panel.md`).
- **Identifier exposure differs.** OpenEMR exposes the CAH MRN as `pubpid`
  under the generic `v2-0203` "PT" system; the channel reads that value and
  the transform stamps the participant URI (`openemr-cah`) HIE-side - same
  pattern as Bahmni (the URI is always an integration-layer overlay).
- **Apache HttpClient, not `java.net.URL`** - the Java 17 / Rhino module
  constraint from ADR 0005 binds here too.

## Rationale
- FHIR R4 polling is again the only general, standards-based export path
  (OpenEMR's appstore/HL7 paths are heavier and less general). Reusing the
  Bahmni pattern - poll, transform, conditional upsert - is what makes the
  onboarding template generic across two very different EHRs (the 3a thesis).
- A1 (each participant's Mirth writes to the HIE) keeps OpenEMR a pure
  participant and exercises the cross-host boundary as a first-class lesson.
- Upsert-by-identifier keeps polling idempotent (re-delivery updates in
  place), so non-incremental polling is safe.

## Consequences
- The CAH Mirth holds the CAH's OAuth client credential (private key) - a
  real per-participant secret-management concern (mounted, gitignored;
  production would use a secrets manager / mTLS).
- **Known limitation:** the patient channel polls the full Patient set each
  cycle (no `_lastUpdated` incremental filter yet, unlike the Bahmni
  channel), re-upserting every minute. Harmless (idempotent) but inflates
  the Mirth message store; add incremental polling before any volume. Noted
  in `docs/runbooks/phase3a-cah-mirth.md`.
- After 3a.5, the HIE holds three-way duplicates for the overlap cohort
  (ADR 0008); 3a.6 verification asserts and 3b/MPI resolves.
- HIE-boundary OAuth (participant authenticating to HAPI) is still **not**
  done - HAPI is written unauthenticated, the carried-forward production
  delta for Phase 3b/Keycloak.

## Related
- ADR 0005 (Gate C, Bahmni) - the pattern this mirrors and diverges from
- ADR 0006 (Gate J) - the cross-host boundary this writes across
- ADR 0008 (Gate I) - the panel + three-way overlap
- `docs/runbooks/phase3a-cah-mirth.md`; issue #31
