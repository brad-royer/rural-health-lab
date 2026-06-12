# ADR 0005 - Gate C: Integration Source and Direction (Bahmni -> HIE)

## Status
Accepted - 2026-06-12

## Context
Phase 2 (`docs/phase2-kickoff-prompt.md`, Gate C) needs patient/encounter
events to flow out of Bahmni (the central hospital's EHR) into the CIN HIE
(HAPI hub), mediated by Mirth like any other participant (Hard Rule #1 /
Topology Clarification in `docs/adr/0001-handoff.md`). Gate C asks which
source mechanism to use - OpenMRS FHIR2 (R4) API polling, Bahmni's atom
feeds, or anything HL7v2-shaped - and fixes direction: outbound
(Bahmni -> Mirth -> HAPI) is required, inbound is a stretch goal only.

Two step-0 findings (recorded on issue #13) bind this ADR:

1. **No Mirth instance existed anywhere** - Phase 1 never deployed one
   (`compose/mirth/` was an empty placeholder). 2.4 therefore stands up
   the CIN's single Mirth instance too ("One Mirth", Hard Rule #3).
2. **Mirth's open-source line ended at 4.5.2.** NextGen took Mirth
   Connect commercial from 4.6 (2024); Docker Hub's
   `nextgenhealthcare/connect` tags stop at `4.5.2`. The same packaging
   drift lesson as 2.2's stale Bahmni tags: verify against the registry,
   don't rely on memory.

## Decision
1. **Source mechanism: poll Bahmni's OpenMRS FHIR2 R4 API**
   (`/openmrs/ws/fhir2/R4/Patient` and `/Encounter`), incrementally via
   `_lastUpdated` (verified working against the running Bahmni), with a
   full resync on channel redeploy. Polling interval 60s.
2. **Direction: outbound only.** Bahmni is strictly read-only to the
   channels; the HIE never writes into Bahmni in Phase 2. Inbound stays
   a stretch goal that this ADR explicitly does not start.
3. **Sink semantics: conditional create/update (upsert) into HAPI keyed
   on identifier** - `Patient?identifier=<system>|<MRN>` under
   `https://lab.example/identifiers/bahmni-central` (ADR 0003), and
   `Encounter?identifier=<system>/encounter|<Bahmni encounter UUID>`.
   HAPI resource ids are never set or overwritten; encounters resolve
   their subject by identifier search, never hardcoded ids.
4. **Engine: Mirth Connect 4.5.2** (last open-source release), one
   instance, deployed in the Phase 1 compose stack on Host #1
   (`compose/docker-compose.yml`), channels committed as XML in
   `compose/mirth/channels/`.

## Rationale
- **FHIR2 R4 polling is the only general-purpose export path of the
  three.** Atom feeds are OpenMRS's intra-Bahmni sync mechanism
  (OpenMRS -> OpenELIS/Odoo), shaped around OpenMRS event internals -
  consuming them couples the HIE to Bahmni's implementation. HL7v2 is
  not natively emitted by Bahmni at all. The FHIR2 API is standard R4
  over HTTP, already validated in 2.3 (seeding) and reusable as the
  template for any FHIR-capable participant - which is what the 2.6
  generic onboarding runbook needs.
- **Polling over eventing keeps the participant contract minimal.** A
  push/subscription model would require configuring Bahmni to know
  about the HIE; polling keeps Bahmni completely passive (it doesn't
  even know Mirth exists), which matches the onboarding narrative -
  the CIN adapts to the participant, not vice versa.
- **Upsert-by-identifier makes the pipeline idempotent**, so polling's
  inherent at-least-once delivery (full resync after redeploy, boundary
  overlap on `_lastUpdated`) is harmless: re-delivery updates in place
  (verified: resync left 16 patients at 16, bumping `versionId` only).
- **4.5.2 pin.** The last open-source release is the only
  reproducible, license-clean choice; the fork landscape (e.g.
  community forks of the 4.5 line) is left for Phase 3 to re-evaluate
  if a CVE or Java compatibility issue forces movement. Recorded
  consequence: no vendor patches will ever arrive for this version.

## Consequences
- The CIN Mirth instance lives in the Phase 1 compose stack
  (`mirth` service, embedded Derby on a named volume, admin/API on
  host port 8443). Production delta: real deployments back Mirth with
  Postgres and put real TLS in front - documented in the 2.4 runbook.
- Channel scripts use Apache HttpClient (bundled with Mirth), not
  `java.net.URL`: on Java 17 the JDK's internal `HttpURLConnection`
  classes aren't exported to Rhino's unnamed module
  (`IllegalAccessException`). This constraint binds all future channel
  work on this instance.
- The Bahmni->HIE identifier system URIs exist only in the Mirth
  transforms (per ADR 0003's dated update - OpenMRS stores no
  identifier system). The type->URI mapping is integration-layer
  configuration; the per-participant registry question is parked
  (`docs/phase3-parking-lot.md` entry #2).
- After the patient channel first syncs, HAPI intentionally holds
  duplicate-person records (Synthea original + Bahmni-sourced copy,
  disjoint identifier systems) - ADR 0003's expected artifact, to be
  called out by 2.5's verification, not "fixed".
- Encounters carry a minimal clinical envelope (identifier, status,
  class, type, period, subject). Bahmni-local references (location,
  participant, partOf visit) are dropped because their targets don't
  exist in the HIE; widening the envelope is future work.

## Related
- `docs/phase2-kickoff-prompt.md` - Gate C
- ADR 0003 (identifier strategy) and its 2026-06-12 dated update
- `docs/runbooks/phase2-mirth-channel.md` - deployment + channel design
- Issue #13 / increment 2.4
