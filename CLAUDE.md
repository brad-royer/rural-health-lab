# Rural Health Tech Lab — Project Memory

## What this is
A personal lab simulating a rural Texas CIN/ACO: a Critical Access Hospital hub
running a centralized HIE (HAPI FHIR R4), spoke provider instances, Mirth Connect
integration, a Medplum patient portal, Keycloak identity, and Synthea synthetic data.
Later phases bridge to Azure Health Data Services and external sandboxes (Epic,
CMS Blue Button) to simulate statewide/nationwide exchange.

**Source of truth for all prior decisions:** `docs/adr/0001-handoff.md`. Read it
before proposing anything that touches architecture or the phase roadmap.
`docs/runbooks/` holds the manual fallback path for every automated task.

## Current Phase Status
- **Phase 1 (Local core) — complete**, tagged `v0.1.0-phase1`: Postgres-backed
  HAPI hub + 2 H2 spokes + full Synthea rural-TX population, reproducible
  from a clean state.
- **Phase 2 (Central hospital EHR) — next**: stand up Bahmni (the central
  hospital's own EHR) on Host #1, with Mirth routing Bahmni ↔ HAPI. See
  `docs/adr/0001-handoff.md` for the full Phase 2 stack and the "Lab
  Narrative" / "Topology Clarification" sections for the scenario this
  builds toward.

## Architectural Invariants (Phase 2+)
These hold regardless of which phase or agent is doing the work:
1. **HIE ≠ EHR.** HAPI FHIR is the CIN's HIE (aggregation/exchange layer) —
   it is never the central hospital's EHR, and the central hospital's EHR
   (Bahmni, then OpenEMR for the acquired CAH) never gets privileged/direct
   access to HAPI's database. Onboarding happens via Mirth-mediated FHIR
   exchange like any other participant. See "Topology Clarification" in
   `docs/adr/0001-handoff.md`.
2. **Synthetic data only — no real PHI, ever**, and no design assumptions
   that only work for real PHI.
3. **PR-based workflow, even solo.** No direct pushes to main.
4. **Every automated task gets a manual runbook** in `docs/runbooks/`.
5. **Agents propose a plan before destructive or infra-changing
   operations** and wait for confirmation.
6. **Host #2 stays unused/idle before Phase 3.** Don't deploy anything there
   early, even if it would be convenient.

## Environment
- Workstation / control plane: Ubuntu on WSL2 (git, Claude Code, terraform/OpenTofu,
  ansible, docker CLI, gh all run here).
- Managed infrastructure (Phase 3+): Hyper-V VMs on the Windows host. WSL2 is NOT
  the infra target — provisioning a real VM is the lesson, not running containers in WSL2.
- Services: Docker Compose (Phases 1–2). Cloud: Azure free tier (Phase 4).

## Non-negotiable rules
1. **Synthetic data only. No real PHI, ever.** This is not a HIPAA environment.
   Model production controls (BAA concepts, IAL2/AAL2, audit logging) as learning,
   not as compliance.
2. **Everything flows through git, PR-based**, even solo. Bootstrap commits aside,
   no direct pushes to main.
3. **Plan before acting on anything destructive or infra-changing.** Show the plan,
   wait for confirmation, then execute.
4. **Every automated task gets a manual runbook** in `docs/runbooks/`. No exceptions —
   if you automate it, document how to do it by hand.
5. **Every completed task updates its GitHub issue.** Reference the issue in the PR.
6. No secrets in the repo. Secrets live in gitignored files (`.env`, `*.tfvars`)
   and never in committed code or tfstate.

## Repo map
- `compose/` — Phase 1–2 Docker topology (hub, spokes, mirth, keycloak, medplum)
- `synthea/` — synthetic population config (generated output is gitignored)
- `infra/` — Phase 3 IaC: terraform/, packer/, ansible/
- `fhir/` — resource templates (Organization, OrganizationAffiliation, CareTeam, Subscription)
- `docs/runbooks/` — manual paths; `docs/adr/` — decisions

## Subagents (.claude/agents/)
- `infra-engineer` — Terraform/OpenTofu, Ansible, Docker Compose, Hyper-V/PowerShell.
- `fhir-interop` — HAPI FHIR, Synthea, Mirth channels, FHIR resource modeling, Keycloak/Medplum.
- `project-ops` — GitHub issues/Projects, PR hygiene, runbook completeness, CMS concept mapping.

## Conventions
- Conventional Commits (`feat:`, `fix:`, `chore:`, `docs:`).
- Branch naming: `feat/…`, `fix/…`, `chore/…`.
- Teach while doing: explain the *why* and name failure modes before the happy path.
