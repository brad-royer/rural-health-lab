# ADR 0004 - Gate A: Bahmni Edition and Sizing

## Status
Accepted - 2026-06-12

## Context
Phase 2 (`docs/phase2-kickoff-prompt.md`, Gate A) onboards Bahmni as the
central hospital's EHR. Known Lessons #7 (`docs/adr/0001-handoff.md`) sets
a binary threshold: **if Host #1 cannot allocate >=16 GB RAM and 4 vCPUs to
the central-hospital VM, fall back** along the ladder Bahmni Standard ->
Bahmni Lite -> vanilla OpenMRS, and document the constraint explicitly
rather than silently undersizing.

Increment 2.1 provisioned `rhl-central-hospital` (Generation 2, 4 vCPU,
Dynamic Memory 2 GB min / 4 GB startup / 16 GB max, 80 GB VHDX, Ubuntu
24.04.4 LTS + Docker) to measure the real input to this gate. Results
(`docs/runbooks/phase2-vm-baseline.md`, "After" section, measured
2026-06-12):

- **Host #1**: 63.7 GB total RAM, 23.2 GB free with the VM running and
  idle (32 logical CPUs, i9-14900KF).
- **VM**: assigned 2 GB (its Dynamic Memory floor), demanding ~0.9 GB at
  idle, 4 vCPUs, Dynamic Memory ceiling configured at 16 GB.
- Bahmni Standard's documented requirement is ~16 GB RAM / 4 vCPU
  (production-grade install). Bahmni Lite needs less (~8 GB) but has a
  ~2 hour first-boot reindex of the ~50k-concept CIEL dictionary.

## Decision
Proceed with **Bahmni Standard**, deployed in increment 2.2 on
`rhl-central-hospital` via its Docker Compose distribution, using the
Dynamic Memory configuration already in place (2 GB min / 4 GB startup /
16 GB max, 4 vCPU) rather than a static 16 GB reservation.

This satisfies Known Lessons #7's threshold: the VM *can* be granted
16 GB and 4 vCPUs (the ceiling is configured and Host #1 has the headroom
to support it), but Dynamic Memory means the host isn't statically
committing 16 GB before Bahmni's actual footprint is known.

**Re-evaluation checkpoint (binds increment 2.2):** while deploying
Bahmni, record the VM's `MemoryDemand` (via `Get-VM` on Host #1) and
Host #1's free RAM under idle and light use, per the kickoff doc's 2.2
scope. If Bahmni Standard's steady-state `MemoryDemand` approaches the
16 GB ceiling (i.e., Host #1 free RAM would drop below roughly 8-10 GB,
the rough headroom the Phase 1 stack plus host OS appear to need based on
the current 23.2 GB-free/idle baseline), stop and fall back to Bahmni
Lite per the ladder - re-provisioning is cheap, since 2.1's VM, seed ISO
tooling, and runbook are reusable as-is (only the Docker Compose stack
changes). If Lite is also needed, document the ~2 hour first-boot CIEL
reindex explicitly in the 2.2 runbook so it isn't mistaken for a hang.

## Rationale
- **Measured, not assumed.** Known Lessons #7's "do not silently
  undersize" instruction is satisfied by measuring real numbers (this
  ADR) rather than picking an edition from documentation alone.
- **Dynamic Memory turns a binary go/no-go into a gradient.** A static
  16 GB allocation against ~21.8 GB pre-VM free RAM (the Phase 2.1
  baseline) would have left uncomfortably little headroom for the Phase 1
  stack and host OS. Configuring 16 GB as a *ceiling* the VM can grow into
  - rather than a floor it always holds - lets Bahmni Standard be tried
  without committing that memory until it's actually needed.
- **The fallback ladder stays cheap.** Because 2.1 already built the VM,
  cloud-init tooling, and runbook generically (Ubuntu 24.04 + Docker), the
  cost of falling back to Lite (or even vanilla OpenMRS) at the 2.2
  checkpoint is "change the Compose stack," not "redo the VM
  provisioning." This keeps the Gate A decision reversible at low cost,
  consistent with treating it as a measured checkpoint rather than a
  one-way door.
- **4 vCPU / Dynamic Memory ceiling both already met.** `Get-VM` confirms
  `ProcessorCount: 4` and a configured Dynamic Memory maximum of 16 GB -
  the two concrete numbers Known Lessons #7 names.

## Consequences
- Increment 2.2 deploys Bahmni Standard's Docker Compose distribution on
  `rhl-central-hospital` and records actual `MemoryDemand`/Host #1 free
  RAM under idle and light use (per `docs/phase2-kickoff-prompt.md`).
- If the 2.2 checkpoint triggers the fallback to Bahmni Lite or vanilla
  OpenMRS, this ADR's "Decision" section must be amended (new dated entry,
  not silently edited) recording the actual measured `MemoryDemand` that
  triggered it, and `docs/runbooks/phase2-vm-baseline.md` /
  `docs/runbooks/participant-onboarding.md` (2.6) updated accordingly.
- The ~8-10 GB headroom figure is a rough planning threshold derived from
  the single idle measurement in this ADR, not a hard budget - increment
  2.2 should treat it as a checkpoint to re-evaluate against, not a
  guarantee.

## Related
- Known Lessons #7 - `docs/adr/0001-handoff.md`
- `docs/phase2-kickoff-prompt.md` - Gate A
- `docs/runbooks/phase2-vm-baseline.md` - measured Host #1/VM numbers
- Increment 2.2 (#12) - Bahmni deployment and the re-evaluation checkpoint
