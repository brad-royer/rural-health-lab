# ADR 0007 - Gate H: OpenEMR Edition and Sizing (Host #2)

## Status
Accepted - 2026-06-13 (with a 3a.3 deployment checkpoint)

## Context
Phase 3a (`docs/phase3a-kickoff-prompt.md`, Gate H) onboards the acquired
CAH's EHR, **OpenEMR**, on Host #2 (PRAETORIAN). Gate H asks which OpenEMR
packaging/edition to use and how to size its VM, measured against real
Host #2 capacity rather than assumed.

Step-0 inventory of Host #2 (i9-9940X, 31.9 GB, 28 logical CPUs, Win 11
Pro) found it is **not idle**: 6 pre-existing user VMs (all **Off**, 0 GB
assigned) and ~8 GB free with the host's own workload (incl. a WSL
instance). This is the user's own machine, not a lab-discipline violation
(Known Lessons #8 is about the *lab* not deploying there early). It does
make headroom the binding sizing input.

## Decision
1. **OpenEMR via the official `openemr/openemr` Docker image** (a LAMP
   stack: Apache/PHP + MariaDB), deployed by Docker Compose in 3a.3.
   Pin the exact image tag verified against Docker Hub at deploy time
   (packaging-drift discipline from Phase 2's Bahmni/Mirth tags) - do not
   rely on memory.
2. **VM sizing: Dynamic Memory 1 GB min / 2 GB startup / 6 GB max, 4 vCPU,
   60 GB dynamic VHDX**, on the `rhl-lan-external` switch. Conservative
   against Host #2's ~8 GB free - OpenEMR's LAMP stack is far lighter than
   Bahmni's OpenMRS/Java, so a 6 GB ceiling is expected to be ample.

Measured at VM baseline (3a.2, idle, no OpenEMR yet): VM assigned 1.23 GB
/ demand 0.75 GB; Host #2 free 6.6 GB with the VM running.

**Re-evaluation checkpoint (binds 3a.3):** after OpenEMR + MariaDB are up
under light use, record the VM's `MemoryDemand` and Host #2 free RAM. If
demand approaches the 6 GB ceiling (Host #2 free dropping below ~2 GB),
either raise the ceiling (there is RAM if Host #2's other workload - e.g.
the idle WSL instance - is trimmed) or note the constraint explicitly.
Do not silently undersize (the Gate A discipline).

## Rationale
- **Measured, not assumed.** Host #2's real free RAM (~8 GB, not the
  nominal 32 GB) is the constraint, so the VM ceiling is set against it.
- **OpenEMR is the light option already.** Unlike Gate A (where Bahmni had
  a Standard->Lite->vanilla-OpenMRS fallback ladder), OpenEMR's LAMP stack
  has no lighter fallback worth a ladder; if it doesn't fit, the lever is
  Host #2 headroom (trim WSL/other), not a smaller EHR.
- **Dynamic Memory makes the ceiling a cap, not a reservation**, so the
  VM only consumes what OpenEMR actually needs - important on a host with
  ~8 GB free shared with the user's workload.

## Consequences
- 3a.3 deploys OpenEMR's Docker Compose stack and records actual
  `MemoryDemand` / Host #2 free RAM under idle and light use against the
  checkpoint above.
- If the checkpoint triggers, this ADR gets a dated update recording the
  measured demand and the chosen remedy (raise ceiling / trim host
  workload), and `docs/runbooks/phase3a-vm-baseline.md` is updated.
- Host #2's pre-existing VMs remain Off and untouched throughout.

## Update - 2026-06-13: 3a.3 deployment checkpoint result

**Checkpoint passed**, comfortably. With OpenEMR 8.1.0 + MariaDB 11.8.8 up
and idle on the VM:
- OpenEMR container 129 MiB, MariaDB 256 MiB (~384 MiB combined - OpenEMR's
  LAMP stack is as light as expected).
- VM guest using 806 MiB; Hyper-V `MemoryDemand` 2.32 GB / assigned 2.9 GB,
  well under the 6 GB ceiling.
- Host #2 free RAM settled at **21.2 GB** (the ~6.6 GB seen at 3a.2 was
  transient - inflated by the in-flight BITS ISO download buffers, not real
  pressure). Headroom is generous; no resize or host-workload trim needed.

`latest` resolved to the **8.1.0** line; the compose pins `openemr/openemr:8.1.0`
and `mariadb:11.8.8` explicitly (`compose/openemr/docker-compose.yml`).
Re-check under heavier load only if a future increment drives real volume.

## Related
- `docs/phase3a-kickoff-prompt.md` - Gate H
- `docs/runbooks/phase3a-vm-baseline.md` - measured Host #2/VM numbers
- `docs/runbooks/phase3a-openemr-deployment.md` - 3a.3 deployment
- ADR 0004 (Gate A) - the Bahmni sizing analog this mirrors
- Increment 3a.2 (#28) / 3a.3 (#29)
