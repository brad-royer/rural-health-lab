# Runbook: Phase 3a.3 — Deploy OpenEMR on the Acquired-CAH VM

Deploys OpenEMR (the acquired CAH's EHR) on `rhl-acquired-cah`
(192.168.1.189, Host #2), per Gate H / ADR 0007. Second worked example of
the "deploy the EHR" template step in `participant-onboarding.md`. Depends
on 3a.2. Entirely control-plane-driven over SSH — no hands-on Host #2 steps.

## Goal

OpenEMR reachable over HTTPS on the LAN, a clinician can log in and register
a patient by hand, and idle/light-use resource usage is recorded against the
ADR 0007 checkpoint.

## Deployment path (over SSH from the control plane)

```bash
KEY=infra/hyperv/cloud-init/.generated/rhl-acquired-cah/id_ed25519_rhl-acquired-cah
VM=ubuntu@192.168.1.189
ssh -i "$KEY" "$VM" 'mkdir -p ~/openemr'
scp -i "$KEY" compose/openemr/docker-compose.yml "$VM":~/openemr/
ssh -i "$KEY" "$VM" 'cd ~/openemr && docker compose pull && docker compose up -d'
```

- Image pins (verified against Docker Hub 2026-06-13, packaging-drift
  discipline): `openemr/openemr:8.1.0`, `mariadb:11.8.8`. `compose/openemr/`
  is committed for reproducibility (unlike Phase 2's Bahmni, which used an
  upstream clone on the VM).
- First boot runs the OpenEMR DB schema install (~3-5 min). Poll readiness:

  ```bash
  ssh -i "$KEY" "$VM" 'docker inspect -f "{{.State.Health.Status}}" openemr-openemr-1'
  # or directly:
  curl -sk -o /dev/null -w "%{http_code}\n" https://192.168.1.189/meta/health/readyz   # 200 = ready
  ```

## Validation (2026-06-13)

- [x] Both containers Up; MariaDB healthy, OpenEMR healthy.
- [x] `https://192.168.1.189/` returns 302 → login; `/meta/health/readyz`
      returns 200, from the VM **and** from the control plane over the LAN
      (the path 3a.6 verification needs).
- [x] Clinician login (`admin`/`pass`) succeeds and a test patient was
      registered by hand through the UI at `https://192.168.1.189/` —
      2026-06-13. Default credentials are lab defaults — flagged to change
      before production-like use.

## Resource usage (ADR 0007 checkpoint — PASS)

Measured 2026-06-13, idle (OpenEMR up, no load):

| | docker stats (openemr / mysql) | VM guest used | VM MemoryDemand | Host #2 free |
|---|---|---|---|---|
| Idle | 129 MiB / 256 MiB | 806 MiB | 2.32 GB (assigned 2.9) | 21.2 GB |

Well under the 6 GB VM ceiling; generous host headroom. No resize needed.

## Note for 3a.5 (Gate K preview)

OpenEMR's FHIR R4 API (`/apis/default/fhir/...`) is **SMART/OAuth2-gated** —
unlike Bahmni's basic-auth FHIR2. Extraction in 3a.5 will require registering
an OAuth client *in OpenEMR* and a token grant (a source-side auth setup
internal to the CAH; distinct from the HIE-boundary OAuth that is Phase 3b).
This is the headline OpenEMR-vs-Bahmni divergence the template must capture.

## Rollback

```bash
ssh -i "$KEY" "$VM" 'cd ~/openemr && docker compose down'      # keep volumes
ssh -i "$KEY" "$VM" 'cd ~/openemr && docker compose down -v'   # erase all data
```

Affects only the `rhl-acquired-cah` VM's Docker state; nothing on the HIE
host or Host #2's other VMs.
