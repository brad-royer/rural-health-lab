# Rural Health Tech Lab — Project Memory

## What this is
A personal lab simulating a rural Texas CIN/ACO: a Critical Access Hospital hub
running a centralized HIE (HAPI FHIR R4), spoke provider instances, Mirth Connect
integration, a Medplum patient portal, Keycloak identity, and Synthea synthetic data.
Later phases bridge to Azure Health Data Services and external sandboxes (Epic,
CMS Blue Button) to simulate statewide/nationwide exchange.

**Source of truth for all prior decisions:** `docs/adr/0001-handoff.md`. Read it
before proposing anything that touches architecture or the phase roadmap.

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
