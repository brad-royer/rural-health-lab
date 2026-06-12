# Rural Health Tech Lab — Handoff Document
*Context carried over from prior planning conversation (June 2026). Upload this to project knowledge so all future chats in this project have this background.*

## Purpose of the Lab
Personal learning environment to simulate a **rural Texas CIN/ACO** with:
- A **Critical Access Hospital (CAH) hub** running a centralized HIE
- **Spoke providers**: RHCs, FQHCs, behavioral health clinics, pharmacy partners
- A **patient-facing portal** with identity verification
- Eventual connectivity patterns toward **statewide and nationwide HIE** (TEFCA-style exchange)

Secondary goals: learn Claude features (Projects, Claude Code, subagents, MCP, skills), practice IaC/CaC discipline, and understand the technology that vendors propose under CMS Health Tech Ecosystem / Rural Health Transformation-style requirements (FHIR exchange, CMS Aligned Networks, IAL2/AAL2 identity, encounter notifications within 24 hours, AI content labeling).

## Lab Narrative

The lab's scenario (set as of Phase 2 planning): an established hospital
already runs a CIN/ACO with a centralized HIE. That hospital acquires a
Critical Access Hospital (CAH) and must onboard it onto the CIN's shared
infrastructure — its own EHR, its own staff, its own systems, now expected to
exchange data with the CIN's HIE like any other participant.

This mirrors the acquisition patterns CMS's Health Tech Ecosystem and Rural
Health Transformation programs are designed around: a rural facility doesn't
get re-platformed onto the acquirer's EHR overnight (or ever, in many real
deals) — it gets *connected*. Onboarding an acquired facility's existing EHR
onto shared HIE infrastructure, with all the integration and identity work
that implies, is the central exercise of Phase 2 and Phase 3.

## Architecture Decisions Already Made
- **Hypervisor:** Hyper-V VMs on Windows host
- **Containers:** Docker (Docker Compose for multi-instance FHIR topology)
- **Cloud (later phase):** Azure free tier (Azure Health Data Services has a free tier; Microsoft is the dominant cloud in Texas state government)
- **IaC/CaC:** Terraform/OpenTofu + Ansible preferred; everything in code, minimal manual configuration
- **Source control:** GitHub (single repo, mono-repo style to start)
- **Agile tooling:** GitHub Projects (issues/boards), updated by agents where possible
- **Agent runtime:** Claude Code (terminal agent) with custom subagents; manual fallback always available

## Topology Clarification

A central hospital's EHR and the CIN's HIE are **separate systems** with
separate roles, even when (as in Phase 1) they happen to run on the same
host:

- **HAPI FHIR is the HIE** — the aggregation/exchange layer. It is not, and
  must never become, "the central hospital's EHR."
- The **central hospital has its own EHR** (Bahmni from Phase 2 onward),
  exactly like the acquired CAH (OpenEMR) or any spoke.
- The central hospital **onboards to the HIE as a participant**, the same
  way the CAH and spokes do — via Mirth-mediated FHIR exchange, not via
  privileged/direct access to HAPI's database.

**The most common conflation in real-world HIE design — and the one this lab
must explicitly avoid — is treating the hub organization's EHR as if it *is*
the HIE.** They are architecturally distinct systems with distinct owners,
even when the same organization operates both. Every Phase 2+ decision
should be checked against this: "am I about to make the central hospital's
EHR a privileged shortcut into the HIE?" If yes, stop.

## Open-Source Stack Selected (updated for Phase 2 planning)
| Component | Tool | Role |
|---|---|---|
| CIN HIE (aggregation) | HAPI FHIR (R4) | Central exchange/aggregation layer — see "Topology Clarification" above |
| Central hospital EHR | Bahmni (OpenMRS + OpenERP + OpenELIS) | The acquiring organization's own EHR; onboards to the HIE as a participant. Fallback: vanilla OpenMRS if the host VM has &lt;16 GB RAM |
| Acquired CAH EHR | OpenEMR | The acquired Critical Access Hospital's existing EHR, onboarded onto shared HIE infrastructure |
| Synthetic patients | Synthea (MITRE) | Full population loaded to HAPI; a small panel seeded per EHR. The mismatch between HAPI's full population and each EHR's small panel is intentional — see "Known Lessons" |
| Integration engine | Mirth Connect | Single instance in Phases 1–2; two instances (one per organization, federation pattern) from Phase 3+ |
| HIE-wide portal | Medplum (initial) | Patient/HIE-wide portal; future direction is a SMART-on-FHIR app vs. HAPI directly. Deferred out of Phase 1 — [ADR 0002](0002-defer-medplum-from-phase-1.md) |
| EHR-native portal | OpenEMR built-in portal | Patient portal local to the acquired CAH |
| Identity/auth | Keycloak (Phase 3 onward) → ID.me sandbox (later) | OAuth2/OIDC simulating IAL2/AAL2 layer |
| Orchestration | Docker Compose (Phases 1–3) → IaC (Phase 4+) | Local topology, then Hyper-V/Terraform/Ansible |

FHIR `Organization`, `OrganizationAffiliation`, and `CareTeam` resources model the ACO structure. FHIR `Subscription` resources simulate the CMS "encounter notification within 24 hours" requirement.

## Commercial Sandboxes/Trials Identified (for comparison learning)
- **Epic** — open.epic.com (free FHIR sandbox; dominant in large TX systems)
- **Oracle Health/Cerner** — code.cerner.com sandbox
- **Azure Health Data Services** — free tier + Azure credit
- **Google Cloud Healthcare API** — 90-day trial
- **AWS HealthLake** — free tier
- **CMS Blue Button 2.0** — sandbox.bluebutton.cms.gov (synthetic Medicare claims via FHIR)
- **ID.me / Login.gov** — developer sandboxes (IAL2 testing)
- **Medplum Cloud** — free tier
- **Canvas Medical** — free sandbox
- **Okta Developer** — free tier (OIDC)
- Demo-only (no self-serve trial): Arcadia, Innovaccer, Azara Healthcare, Salesforce Health Cloud (30-day trial)

## Known Lessons to Pursue in the Lab
1. FHIR Subscription/notification SLAs are operationally hard — feel the latency and config complexity.
2. IAL2/AAL2 identity is a real integration project, not a checkbox — Keycloak then ID.me sandbox.
3. Data normalization at the HIE layer is where real projects fail — Synthea data is clean; real ADT feeds are not. Consider deliberately injecting malformed HL7v2 via Mirth to simulate this.
4. Commercial demos show polished UIs; open-source shows the seams. Use both.
5. **MPI/EMPI matching, record dedup, and ID reconciliation are Phase 3+ concerns, not Phase 2.** Phase 2's job is "both EHRs exchange with the HIE." Phase 3+'s job is "the same patient now exists in both — decide what to do about it."
6. **Synthea will not load cleanly into Bahmni or OpenEMR — this is intentional.** Each EHR gets seeded with a small hand-managed patient panel; the full Synthea population lives only in HAPI. The mismatch between "what the HIE has" and "what each EHR has" is itself the learning surface, not a bug to fix.
7. **If Host #1 cannot allocate ≥16 GB RAM and 4 vCPUs to the central hospital VM, fall back to vanilla OpenMRS** and document the constraint explicitly in the Phase 2 runbook — don't silently undersize Bahmni and fight performance issues.
8. **Host #2 stays idle through Phases 1–2 by design.** Resist the temptation to deploy anything there early — standing it up only in Phase 3 is itself part of the lesson (acquired-facility infrastructure isn't touched until the integration plan is ready).
9. **Phase 3 uses two Mirth instances — one per organization (federation pattern) — not one Mirth straddling both organizations.** A single shared integration engine spanning two orgs is an anti-pattern this lab should demonstrate avoiding, not adopt for convenience.

## Roadmap Phases (updated for Phase 2 planning)
- **Phase 1 — HIE core (DONE):** HAPI hub + bare spoke(s) + full Synthea population + minimal Mirth. Tagged `v0.1.0-phase1`.
- **Phase 2 — Central hospital EHR:** Stand up Bahmni (the central hospital's own EHR) on Host #1. Mirth routes Bahmni ↔ HAPI. Write the onboarding runbook as the template Phase 3 will reuse for the acquired CAH.
- **Phase 3 — Acquired CAH:** Stand up OpenEMR (the acquired CAH's EHR) on Host #2. Second Mirth instance at the CAH (federation pattern — one Mirth per organization). Add Keycloak, FHIR Subscriptions, and cross-host networking between Host #1 and Host #2.
- **Phase 4 — Infrastructure as Code:** Hyper-V VM provisioning via Packer + Terraform/OpenTofu; Ansible for configuration; GitHub Actions CI. Two IaC workspaces, one per host.
- **Phase 5 — Statewide HIE bridge:** Azure Health Data Services free tier as the "statewide HIE" target — simulates local→state tiering.
- **Phase 6 — Nationwide exchange comparison:** Connect the lab to the Epic sandbox / CMS Blue Button to simulate nationwide exchange patterns.

## Hardware Topology

Two physical hosts, used asymmetrically across phases:

- **Host #1 — Alienware Aurora R16** (Intel i9-14900KF, 64 GB RAM, U.2 SSD):
  runs the central hospital's stack (Bahmni, ~16 GB) plus the CIN HIE stack
  (HAPI, Mirth, Keycloak, Medplum portal). Estimated lab footprint ~36 GB.
- **Host #2 — Alienware Area-51 R5** (Intel i9-9940X, 32 GB RAM): runs the
  acquired CAH's stack (OpenEMR + its database + a local Mirth instance).
  Estimated lab footprint ~16 GB.

**Phases 1–2: Host #1 only.** Host #2 is intentionally idle — see "Known
Lessons" item 8.

**Phase 3+: two-host distributed topology.** Cross-host networking between
Host #1 and Host #2 is itself one of the lessons, not incidental plumbing.

- **Phase 3 networking starter:** both hosts on the same LAN; a Hyper-V
  external vSwitch per host; local DNS for service discovery; Windows
  Defender Firewall rules to control traffic between the two organizations'
  segments.
- **Phase 4+ upgrade:** introduce a pfSense/OPNsense VM as the inter-org
  router/firewall, replacing the ad-hoc firewall-rule approach with something
  closer to a real inter-organizational network boundary.

## Working Agreements
- All infrastructure changes flow through Git (PR-based, even solo).
- Agents propose plans before executing destructive or infra-changing operations.
- Every agent-completed task updates the corresponding GitHub issue.
- Manual execution path documented in runbooks (`/docs/runbooks/`) for every automated task.
- No real PHI ever — synthetic data only (Synthea). This is a personal lab, not a HIPAA environment.
