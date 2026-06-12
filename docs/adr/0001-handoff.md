# Rural Health Tech Lab — Handoff Document
*Context carried over from prior planning conversation (June 2026). Upload this to project knowledge so all future chats in this project have this background.*

## Purpose of the Lab
Personal learning environment to simulate a **rural Texas CIN/ACO** with:
- A **Critical Access Hospital (CAH) hub** running a centralized HIE
- **Spoke providers**: RHCs, FQHCs, behavioral health clinics, pharmacy partners
- A **patient-facing portal** with identity verification
- Eventual connectivity patterns toward **statewide and nationwide HIE** (TEFCA-style exchange)

Secondary goals: learn Claude features (Projects, Claude Code, subagents, MCP, skills), practice IaC/CaC discipline, and understand the technology that vendors propose under CMS Health Tech Ecosystem / Rural Health Transformation-style requirements (FHIR exchange, CMS Aligned Networks, IAL2/AAL2 identity, encounter notifications within 24 hours, AI content labeling).

## Architecture Decisions Already Made
- **Hypervisor:** Hyper-V VMs on Windows host
- **Containers:** Docker (Docker Compose for multi-instance FHIR topology)
- **Cloud (later phase):** Azure free tier (Azure Health Data Services has a free tier; Microsoft is the dominant cloud in Texas state government)
- **IaC/CaC:** Terraform/OpenTofu + Ansible preferred; everything in code, minimal manual configuration
- **Source control:** GitHub (single repo, mono-repo style to start)
- **Agile tooling:** GitHub Projects (issues/boards), updated by agents where possible
- **Agent runtime:** Claude Code (terminal agent) with custom subagents; manual fallback always available

## Open-Source Stack Selected (from prior conversation)
| Component | Tool | Role |
|---|---|---|
| Central HIE (CAH hub) | HAPI FHIR (R4) | Main FHIR server |
| Spoke providers | HAPI FHIR (2–3 lightweight instances) | Simulated partner EMRs |
| Synthetic patients | Synthea (MITRE) | Rural TX population, chronic disease config (diabetes, hypertension) |
| Integration engine | Mirth Connect | Hub↔spoke routing; closest to real HIE architecture |
| Patient portal | Medplum | Fastest working portal UI; FHIR-native — **superseded by [ADR 0002](0002-defer-medplum-from-phase-1.md): deferred out of Phase 1** |
| Identity/auth | Keycloak | OAuth2/OIDC simulating IAL2/AAL2 layer |
| Orchestration | Docker Compose | Local topology |

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

## Roadmap Phases (agreed direction)
- **Phase 1 — Local core:** Docker Compose on one VM: HAPI hub + 2 spokes + Synthea data + Medplum portal. (1–2 days est.)
- **Phase 2 — Real HIE plumbing:** Mirth Connect routing, FHIR Subscriptions, Keycloak auth. (2–3 days est.)
- **Phase 3 — Infrastructure as Code:** Hyper-V VM provisioning automated (PowerShell DSC or Packer + Terraform), Ansible for config, GitHub Actions CI.
- **Phase 4 — Cloud bridge:** Azure Health Data Services free tier as the "statewide HIE" target; lab hub exchanges with it — simulates local→state→national tiering.
- **Phase 5 — Commercial comparison:** Connect lab to Epic sandbox / CMS Blue Button to simulate nationwide exchange patterns.

## Working Agreements
- All infrastructure changes flow through Git (PR-based, even solo).
- Agents propose plans before executing destructive or infra-changing operations.
- Every agent-completed task updates the corresponding GitHub issue.
- Manual execution path documented in runbooks (`/docs/runbooks/`) for every automated task.
- No real PHI ever — synthetic data only (Synthea). This is a personal lab, not a HIPAA environment.
