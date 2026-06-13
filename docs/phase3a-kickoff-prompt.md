# Phase 3a Kickoff — Onboard the Acquired CAH (OpenEMR) Across the Cross-Host Boundary

You are starting Phase 3a of the rural health tech lab. Phase 2 (central
hospital EHR Bahmni onboarded to the CIN HIE via Mirth) is complete and
tagged `v0.2.0-phase2`.

Phase 3 from the handoff (`docs/adr/0001-handoff.md`) is split into two
slices (decided during scoping, 2026-06-12):

- **Phase 3a (this doc) — "the acquired CAH joins the network":**
  cross-host networking, Host #2 VM, OpenEMR, seed panel, the CAH's own
  Mirth, federation into the HIE, verification. This is mostly *applying*
  the Phase 2 Participant Onboarding Runbook to a second, different EHR on
  a second host — the test of whether that template is actually generic.
- **Phase 3b (separate kickoff, later) — "make the exchange
  production-shaped":** Keycloak/OAuth on the HIE boundary, FHIR
  Subscriptions (CMS 24h encounter-notification SLA), and MPI/record
  linkage for the now three-way duplicate-person problem.

## Step 0 — Inventory before planning (do this first, change nothing)

Read `CLAUDE.md`, `/docs` (handoff, ADRs 0003/0004/0005,
`participant-onboarding.md` and the Phase 2 increment runbooks,
`phase3-parking-lot.md`), and the repo itself. Produce a short written
summary of what Phase 2 *actually* deployed and what state Host #2 is in
**right now** (it should be untouched per Known Lessons #8 — verify, don't
assume). Confirm the participant-onboarding template's parameter sheet and
the `verify-onboarding.py` env-var seams are as documented.

## Step 1 — Plan before executing

Per working agreements, propose a written Phase 3a plan and a GitHub issue
breakdown (one issue per increment below, under a Phase 3a milestone) and
wait for approval before any infrastructure change. Every increment ships
as a PR. Every completed increment updates its issue. **Cross-host
networking and standing up Host #2 are infra-changing — plan and confirm
before touching either.**

## Mission

Onboard the acquired CAH's own EHR (OpenEMR) onto the CIN HIE (HAPI FHIR)
**as participant #2**, running on **Host #2**, with **its own Mirth
instance** (federation, one Mirth per organization), exchanging across a
real **cross-host network boundary** between the two organizations.

The real deliverable is **proof that the Participant Onboarding Runbook
generalizes** — OpenEMR is a deliberately different EHR (LAMP/PHP, not
OpenMRS/Java; SMART-OAuth FHIR API, not basic-auth). If onboarding it is
"fill in the parameter sheet and follow the steps," the template
succeeded. Every place OpenEMR forces a divergence from the Bahmni worked
example is a finding to capture in the runbook, not a quiet workaround.

## Hard rules — violating any of these means STOP and ask the human

1. **HAPI is the HIE, not any participant's EHR.** OpenEMR exchanges with
   HAPI only through Mirth-mediated FHIR. No direct DB writes, no pointing
   OpenEMR at HAPI, no privileged shortcuts (handoff: Topology
   Clarification).
2. **Federation is A1 — each org's Mirth writes to the HIE directly.**
   The CAH's Mirth runs on Host #2 and writes to the HIE's HAPI on Host #1,
   authenticating as itself across the boundary. Do **not** route the CAH
   through the central hospital's Mirth (that's the rejected "edge/broker"
   A2 model), and do **not** let one Mirth straddle both orgs (Known
   Lessons #9). Two Mirths total, one per organization.
3. **Do not load Synthea into OpenEMR.** OpenEMR gets a small hand-managed
   panel, same as Bahmni (Known Lessons #6). The HIE-vs-EHR population
   mismatch is the learning surface; do not "fix" it.
4. **Cross-host networking is a first-class lesson, not incidental
   plumbing** (handoff: Hardware Topology). The two organizations are
   network-segmented; traffic between them is deliberately controlled
   (firewall rules), not wide open. Model the org boundary, don't bulldoze
   it for convenience.
5. **No Keycloak / HIE-side OAuth yet — that is Phase 3b.** The CAH Mirth
   writes to HAPI the same (unauthenticated) way Bahmni's does today. This
   knowingly carries the Phase 2 production-delta forward one more slice;
   note it, don't fix it here. (Caveat: OpenEMR's *own* FHIR API may
   require OAuth to read *from* OpenEMR — that is source-side extraction
   auth, internal to the CAH, and is in scope for 3a as part of Gate K. It
   is not the HIE-boundary OAuth that Keycloak will provide in 3b.)
6. **No FHIR Subscriptions — Phase 3b.**
7. **No MPI/dedup/record-linkage work.** Onboarding OpenEMR makes the
   duplicate-person problem three-way (same human in Synthea, Bahmni, and
   OpenEMR under three disjoint identifier systems). That is deliberate
   3b-bait. Record every linkage question in `docs/phase3-parking-lot.md`
   and move on (Known Lessons #5).
8. **No Terraform / Ansible / Packer.** IaC is Phase 4. Host #2 VM
   provisioning is PowerShell (generalize the Phase 2 script) plus runbook
   steps; services are Docker Compose; networking is Hyper-V vSwitch +
   Windows Defender Firewall rules, configured by documented steps.
9. **No pfSense/OPNsense.** The inter-org router/firewall appliance is the
   Phase 4 networking upgrade (handoff). Phase 3a uses the per-host
   vSwitch + firewall-rule starter.
10. **Synthetic data only.** No real PHI, ever.

## Non-goals (do not reintroduce these, even as improvements)

Keycloak / HIE-boundary OAuth · FHIR Subscriptions · MPI/EMPI tooling ·
pfSense/OPNsense · Terraform/Ansible/Packer · Medplum portal · a third
Mirth · any change to the running Bahmni/HAPI/Phase-2-Mirth stack beyond
what onboarding participant #2 strictly requires.

## Decision gates — resolve early, each produces an ADR in /docs/adr/

**Gate H — OpenEMR edition and sizing on Host #2.** Check current OpenEMR
container packaging (the official `openemr/openemr` image and its compose
examples — verify against the registry, do not rely on memory; packaging
drift bit Bahmni and Mirth in Phase 2). Confirm Host #2 (32 GB) hosts
OpenEMR + its MariaDB + the CAH Mirth comfortably. OpenEMR is a far
lighter LAMP stack than Bahmni, so expect headroom — but measure and set
the fallback/sizing note anyway (the Gate A discipline).

**Gate I — CAH panel identity strategy.** Mirror ADR 0003: the OpenEMR
panel reuses demographics from the Synthea population (same humans),
identifiers fully disjoint under a **new CAH-specific system URI** (e.g.
`https://lab.example/identifiers/openemr-cah`). Recommended additional
twist: **deliberately overlap some patients with the Bahmni panel too**,
so a subset of humans exists in all three of Synthea, Bahmni, and OpenEMR
under three different identifier systems — the hardest, most realistic
record-linkage case to hand to 3b's MPI work. Justify and write the ADR;
do NOT act on the dedup implications.

**Gate J — Cross-host networking and service discovery.** Specify the
inter-org topology per the handoff starter: a Hyper-V external vSwitch per
host, both hosts on the same LAN, service discovery (local DNS vs.
hosts-file/static entries), and Windows Defender Firewall rules that allow
**only** the flows onboarding requires across the org boundary (the CAH
Mirth → HIE HAPI write path, plus admin/SSH as needed) rather than open
connectivity. The point is to *feel* the org boundary. Document what is
allowed, what is denied, and why.

**Gate K — OpenEMR integration source and direction.** Investigate how to
get patient/encounter events out of OpenEMR: its FHIR R4 API (SMART /
OAuth2-gated by default — this likely requires registering an OAuth client
*in OpenEMR* and a token grant, an interesting divergence from Bahmni's
basic-auth FHIR2 that the runbook must capture), its standard REST API, or
HL7. Recommend one with tradeoffs. Scope: **outbound (OpenEMR → CAH Mirth
→ HAPI) is required; inbound is a stretch goal.** If OpenEMR's FHIR API
auth model meaningfully complicates extraction, that is itself a finding —
note whether it pulls a *source-side* OAuth setup into 3a (allowed; it is
internal to the CAH) versus the *HIE-side* OAuth that stays in 3b.

## Work breakdown (refine in your plan; each is an issue + PR)

- **3a.1 — Cross-host networking baseline** (per Gate J). Host #2 reachable
  from Host #1 over the controlled boundary; vSwitch per host; firewall
  rules; service discovery. Runbook with the manual path. Prove the
  CAH-segment → HIE-HAPI flow works and disallowed flows are blocked.
- **3a.2 — Acquired-CAH VM baseline on Host #2.** Generalize the Phase 2
  Hyper-V PowerShell script (parameterize host/name/sizing), Docker +
  Compose installed, runbook. Record Host #2 before/after resource usage
  (Phase 4 capacity input). This is template step 1, second worked example.
- **3a.3 — OpenEMR deployment** (per Gate H) via Docker Compose. Smoke
  test: clinician logs in, registers a patient by hand. Record RAM/CPU.
  Template step 2.
- **3a.4 — Seed the CAH patient panel** (per Gate I). Small, scripted,
  idempotent, CAH-specific identifier system, deliberate cross-EHR
  demographic overlap. Template step 3.
- **3a.5 — CAH Mirth instance + channels** (per Gate K, federation A1). A
  second Mirth on Host #2 that polls OpenEMR, transforms, and conditionally
  upserts into the HIE's HAPI across the cross-host boundary, keyed on the
  CAH identifier system URI. Never set/overwrite HAPI resource IDs;
  resolve encounter subjects by identifier. Template step 4.
- **3a.6 — Verification.** Run the **existing** `scripts/verify-onboarding.py`
  against OpenEMR using only its parameter-sheet env vars. It must PASS
  unmodified except for the documented EHR-native seam (the script's
  source-EHR-specific calls). Assert the Synthea **and** Bahmni populations
  in HAPI are unchanged; assert the CAH patient/encounter round-trips. A
  green run with only env-var changes is the proof the template is generic.
  Template step 5.
- **3a.7 — Participant Onboarding Runbook: second worked example.** Fill in
  the OpenEMR column of the parameter sheet; add OpenEMR worked-example
  callouts wherever it diverged from Bahmni (Gate K auth, cross-host
  transport); promote cross-host networking to a proper template step (it
  was implicit when everything ran on one host). If the template needed
  structural changes to fit OpenEMR, that is a finding about the template,
  not just OpenEMR.

## Working agreements (restated; they bind you)

PR-based workflow even though solo. Propose plans before destructive or
infra-changing operations. Every automated step has a documented manual
path in `/docs/runbooks/`. Every completed task updates its GitHub issue.

## Definition of done

- An OpenEMR-registered patient + encounter appears in HAPI via the **CAH's
  own Mirth on Host #2, across the cross-host boundary**, demonstrated by
  `verify-onboarding.py` run with only parameter-sheet env-var changes.
- The HIE's existing Synthea and Bahmni populations are provably unchanged
  by the onboarding (additive only).
- `participant-onboarding.md` updated: OpenEMR column filled, cross-host
  networking promoted to a template step, divergences captured. The
  template now has two worked examples and is demonstrably generic.
- ADRs for Gates H, I, J, K merged.
- Host #2 resource usage recorded (Phase 4 capacity-planning input).
- Cross-host networking runbook merged.
- The three-way duplicate-person questions appended to
  `docs/phase3-parking-lot.md`, still not acted on (handed to 3b).
- Tag `v0.3.0-phase3a`.
