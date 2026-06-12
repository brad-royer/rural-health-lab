# Runbook: Phase 2.2 - Bahmni Deployment (rhl-central-hospital)

Deploys Bahmni Standard (EMR profile, per
`docs/adr/0004-gate-a-bahmni-edition-and-sizing.md`) on the
`rhl-central-hospital` VM provisioned in increment 2.1
(`docs/runbooks/phase2-vm-baseline.md`). This is interim documentation -
it will be folded into the generic `docs/runbooks/participant-onboarding.md`
(2.6) as the "deploy the EHR" step. The pre-existing stub at
`docs/runbooks/phase-2-central-hospital-ehr.md` is superseded by that
runbook and not maintained in parallel.

## Goal

OpenMRS-based Bahmni clinical app reachable over HTTPS on the LAN, a
clinician can log in and register a patient by hand, and actual RAM/CPU
under idle and light use are recorded against the ADR 0004 re-evaluation
checkpoint.

## Prerequisites

- Increment 2.1 complete: `rhl-central-hospital` running, reachable via
  SSH (`docs/runbooks/phase2-vm-baseline.md`).
- Git is preinstalled on the VM's Ubuntu 24.04 image.

## Deployment path

All commands run **on the VM** (SSH from WSL2, per 2.1's runbook):

```bash
ssh -i infra/hyperv/cloud-init/.generated/id_ed25519_central-hospital ubuntu@192.168.1.230
```

1. **Clone `Bahmni/bahmni-docker`** (shallow clone is sufficient):

   ```bash
   git clone --depth 1 https://github.com/Bahmni/bahmni-docker.git ~/bahmni-docker
   cd ~/bahmni-docker/bahmni-standard
   ```

2. **Fix two stale image tags in `.env`.** The repo's checked-in `.env`
   (stable `1.0.0`-line tags, "recommended for production" per the repo's
   README) references two images that no longer exist on Docker Hub:
   `bahmni/openmrs:1.1.2` and `bahmni/bahmni-template-service:1.0.0`. This
   is exactly the kind of packaging drift Gate A's "check current docs, do
   not rely on memory" note anticipated - verify against Docker Hub
   yourself if this recurs:

   ```bash
   curl -s "https://hub.docker.com/v2/repositories/bahmni/<image>/tags?page_size=100" \
     | python3 -c "import json,sys; print(sorted(t['name'] for t in json.load(sys.stdin)['results']))"
   ```

   Create a corrected `.env.local` (keeps everything else on the stable
   `.env` baseline - `COMPOSE_PROFILES=emr` - rather than switching to
   `.env.dev`'s `latest` tags everywhere):

   ```bash
   sed -e 's/^OPENMRS_IMAGE_TAG=1.1.2/OPENMRS_IMAGE_TAG=1.1.3/' \
       -e 's/^TEMPLATE_SERVICE_IMAGE_TAG=1.0.0/TEMPLATE_SERVICE_IMAGE_TAG=1.0.0-3/' \
       .env > .env.local
   ```

3. **Pull and start** (the default `.env`/`.env.local` ships with
   `COMPOSE_PROFILES=emr` - the lean EMR-only core: `proxy`, `bahmni-config`,
   `openmrs` + `openmrsdb`, `bahmni-web`, `bahmni-apps-frontend`,
   `template-service`, `implementer-interface`, `patient-documents`,
   `appointments`, `ipd`. No OpenELIS/Odoo/PACS/Reports/Metabase/CDSS):

   ```bash
   docker compose --env-file .env.local pull
   docker compose --env-file .env.local up -d
   ```

   OpenMRS takes roughly 1-2 minutes to become reachable on first start
   (Tomcat boot + DB init). Poll:

   ```bash
   curl -sk -o /dev/null -w "%{http_code}\n" https://localhost/openmrs/
   ```
   `302` means it's up.

4. **Log in via browser** from any LAN host: `https://192.168.1.230/`
   (self-signed cert - browser will warn, proceed anyway). Default
   credentials: `superman` / `Admin123` (a well-known Bahmni default -
   fine for this synthetic lab, but flagged here as "change before
   anything resembling production").

## Validation checks

- [x] All 11 `emr`-profile containers `Up` (`docker compose --env-file
      .env.local ps`).
- [x] `https://<vm-ip>/openmrs/` returns `302` (OpenMRS reachable through
      the proxy).
- [x] `https://<vm-ip>/` (Bahmni home) returns `200`.
- [x] Clinician login (`superman`/`Admin123`) succeeds and a test patient
      was registered by hand through the UI - 2026-06-12.
- [x] Separate system from HAPI (Hard Rule #1 / Topology Clarification):
      Bahmni's OpenMRS + MySQL run in their own Docker Compose project on
      `rhl-central-hospital`, an entirely separate VM/Docker daemon from
      the Phase 1 HAPI/Postgres stack (Host #1/WSL2). No shared network,
      volume, or DB credentials between the two. The only planned
      connection is Mirth-mediated FHIR exchange (2.4).

## Resource usage (ADR 0004 checkpoint)

Measured 2026-06-12, `rhl-central-hospital` (4 vCPU, Dynamic Memory 2/4/16
GB; Host #1 = 63.7 GB total RAM):

| | Host #1 free RAM | VM `MemoryAssigned` | VM `MemoryDemand` | VM guest `free -h` | `docker stats` (openmrs / openmrsdb) |
|---|---|---|---|---|---|
| **Idle** (2.1 baseline, no Bahmni) | 23.2 GB | 2.0 GB | 0.88 GB | 1.8 GiB total | - |
| **Idle** (Bahmni `emr` profile up, settled) | - | - | - | 5.8 GiB total, 384 MiB free | 1.29 GiB / 613 MiB |
| **Light use** (after login + 1 patient registration) | 17.8 GB | 6.14 GB | 5.03 GB | 6.0 GiB total, 358 MiB free | 1.39 GiB / 644 MiB |

**Checkpoint result: PASS.** Bahmni Standard's `emr` profile demands ~5 GB
at light use - well under the 16 GB Dynamic Memory ceiling, and Host #1
retains ~17.8 GB free (above the ~8-10 GB headroom threshold in ADR 0004).
No fallback to Bahmni Lite / vanilla OpenMRS is needed. CPU was idle (<1%)
across all containers except brief spikes during OpenMRS's own startup.

## Rollback procedure

On the VM:

```bash
cd ~/bahmni-docker/bahmni-standard
docker compose --env-file .env.local --profile emr down       # stop, keep volumes
docker compose --env-file .env.local --profile emr down -v    # stop and erase all data
rm -rf ~/bahmni-docker                                          # remove the clone
```

This only affects `rhl-central-hospital`'s own Docker state - it does not
touch the Phase 1 HAPI/Postgres stack (Host #1/WSL2) or Host #2.
