# Phase 3b Kickoff — Production-Shape the Exchange (MPI, Subscriptions, Identity)

You are starting Phase 3b of the rural health tech lab. Phase 3a (the acquired
CAH's OpenEMR onboarded across the cross-host boundary) is complete and tagged
`v0.3.0-phase3a`. Phase 3 was split during scoping (2026-06-12) into 3a ("the
acquired CAH joins the network") and **3b ("make the exchange
production-shaped")** — this doc.

## Structure (decided during scoping, 2026-06-14)

**One Phase 3b**, three sequenced increment-groups in this order — the first
two are additive and HIE-side; Keycloak is the invasive auth retrofit, done
last so it doesn't rework the others:

1. **MPI / record linkage** — HAPI's built-in MDM, **link-not-merge**, against
   the three-way duplicate set 3a built.
2. **FHIR Subscriptions** — the CMS "encounter notification within 24h" SLA.
3. **Keycloak / HIE-boundary OAuth** — participants authenticate to the HIE
   (the standing production delta), simulating IAL2/AAL2.

## Step 0 — Inventory before planning (do this first, change nothing)

Read `CLAUDE.md`, `/docs` (handoff Known Lessons #1/#2/#5, ADRs 0003–0009,
`phase3-parking-lot.md`, `participant-onboarding.md`), and the repo. Confirm
the current HIE state: HAPI `v8.10.0-1` holds 144 patients (113 Synthea + 16
`bahmni-central` + 15 `openemr-cah`) with the deliberate three-way duplicate
cohort; both participant Mirths write to HAPI **unauthenticated** today.
Verify HAPI's MDM + rest-hook subscription config knobs and how the
`hapiproject/hapi` image takes configuration (env vs. mounted
`application.yaml`) — do not assume.

## Step 1 — Plan before executing

Propose a written plan and a GitHub issue breakdown (one issue per increment,
under a Phase 3b milestone) and wait for approval before infra changes. **One
increment per branch + PR; every completed increment closes its issue** (the
cadence correction from 3a). Enabling MDM/subscriptions and putting auth in
front of HAPI all **reconfigure/restart the live HIE** — plan and confirm each.

## Mission

Make the working two-participant exchange production-shaped along three axes
the lab has deferred: **resolve the duplicate-person problem** (link, don't
merge), **notify on encounters within an SLA**, and **authenticate
participants to the HIE**. The deliverables are the *lessons felt* (matching is
hard with lossy data; subscription SLAs are operationally hard; identity is a
real integration project), captured in ADRs and runbooks.

## Hard rules — violating any of these means STOP and ask the human

1. **Do not break the working 3a federation.** Both participant Mirths must
   keep delivering to HAPI throughout; the Keycloak retrofit updates the write
   path deliberately and is re-verified, not left broken.
2. **MPI is link-not-merge, non-destructive.** Golden records + `Patient.link`
   only; never delete/merge/overwrite source Patient resources. The three-way
   duplicate cohort stays intact as source records.
3. **HIE ≠ EHR** still holds — no privileged EHR access; auth is added at the
   HIE boundary, not by collapsing the topology.
4. **Synthetic data only.** No real PHI, ever. IAL2/AAL2 is *modeled*, not a
   compliance claim (Known Lessons #2).
5. **No Terraform/Ansible/Packer** (Phase 4); no Azure (Phase 5); no pfSense
   (Phase 4). Services are Docker Compose; HIE reconfig is config + restart.
6. **Every reconfigure/restart of the live HIE is plan-and-confirm** (Hard
   Rule #5 lineage) and has a documented rollback.

## Non-goals (do not reintroduce, even as improvements)

Medplum / HIE-wide portal UI · ID.me/Login.gov bridge (Phase 5) · malformed
HL7v2 / ADT normalization (Known Lessons #3, a separate lesson) · merging or
deduplicating away the source duplicates · Terraform/Ansible/Packer · Azure ·
pfSense · a third participant EHR.

## Decision gates — resolve early, each produces an ADR in /docs/adr/

**Gate L — MPI matching rules & linkage policy.** With HAPI MDM enabled,
decide the matching rules (what to key on given lossy demographics — Synthea
vs. EHR round-trip loss, parking-lot #1): name + DOB + gender weighting, and
whether address participates at all (it's the lossiest field). Confirm
link-not-merge (golden record + `Patient.link`). Fold in the
**identifier-system registry + no-reuse policy** (parking-lot #2/#3/#5): the
HIE owns the participant type→URI mapping, identifiers are never reused.

**Gate M — Subscription mechanism & subscriber.** HAPI rest-hook
`Subscription` on new `Encounter` (the CMS 24h notification). Decide the
subscriber (a Mirth channel, a lightweight webhook receiver, or notify a
participant) and what "within 24h" means in lab time (simulate + measure
latency; do not build hard SLA enforcement). Known Lessons #1 — the point is
to feel the config/latency pain.

**Gate N — Keycloak / OAuth scope.** What Keycloak secures: the **HIE write
boundary first** — each participant gets an OAuth client (client-credentials),
HAPI validates tokens (built-in JWT/OAuth validation or a fronting proxy), and
both Mirths obtain + present tokens. Decide how deep to model IAL2/AAL2
(realm/authenticator config as learning) and whether any human/portal OIDC
flow is in scope (recommend: stretch only). The existing unauthenticated write
path is replaced and re-verified.

## Work breakdown (refine in your plan; each is an issue + PR)

- **3b.1 — Enable HAPI MDM + matching rules** (Gate L). Reconfigure HAPI
  (MDM on, rules JSON), restart, runbook + rollback. Record what config knob
  the image uses.
- **3b.2 — Run + verify linkage.** MDM over the existing population; assert
  golden records + `Patient.link` correctly link the three-way duplicates
  without merging sources; document the matching outcomes (including any false
  matches/misses — the lesson). Identifier-registry + no-reuse policy doc.
- **3b.3 — Enable FHIR Subscriptions + subscriber** (Gate M). Rest-hook
  `Subscription` on `Encounter`; stand up the subscriber; runbook.
- **3b.4 — Verify the notification path.** Encounter created in a participant
  EHR → flows to HAPI → Subscription fires → subscriber receives within the
  simulated SLA; measure + record the latency/config friction.
- **3b.5 — Stand up Keycloak** (Gate N). Realm, participant clients
  (client-credentials), checked-in config; `compose/keycloak/`.
- **3b.6 — Put HAPI behind OAuth.** HAPI validates tokens; update **both**
  Mirths' channels to obtain + present tokens; re-run
  `verify-onboarding.py --ehr {bahmni,openemr}` against the **authenticated**
  write path — both must still PASS.
- **3b.7 — Close the loop.** Update `participant-onboarding.md` (auth step;
  retire the "HIE-boundary OAuth" production-delta), ADRs L/M/N merged.

## Working agreements (restated; they bind you)

PR-based, one increment per PR, even solo. Propose plans before destructive or
infra-changing operations. Every automated step has a documented manual path
in `/docs/runbooks/`. Every completed task closes its GitHub issue.

## Definition of done

- The three-way duplicate cohort is linked by HAPI MDM into golden records via
  `Patient.link`, sources intact (link-not-merge), with the matching rules and
  outcomes documented.
- An encounter in a participant EHR triggers a FHIR Subscription notification
  to the subscriber, with the latency/config experience recorded (Known
  Lessons #1).
- Both participant Mirths authenticate to the HIE via Keycloak-issued tokens;
  `verify-onboarding.py` PASSes for both EHRs against the authenticated HAPI;
  the HIE-boundary-OAuth production delta is retired.
- ADRs for Gates L, M, N merged; identifier-registry/no-reuse policy recorded.
- `participant-onboarding.md` updated (auth step); parking-lot identity
  questions resolved or explicitly carried forward.
- Tag `v0.4.0-phase3b`.
