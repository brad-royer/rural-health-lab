# Runbook: Phase 3b.2 — Run + Verify MDM Linkage

Links the three-way duplicate cohort with HAPI MDM (link-not-merge, per Gate L
/ ADR 0010) and verifies it, without mutating the source records. Depends on
3b.1 (MDM enabled).

## The headline lesson — ordered submit, not bulk

A naive bulk `POST /Patient/$mdm-submit` of the whole population **does not
collapse duplicates**:
- all resources process concurrently, so a duplicate's candidate search runs
  before the other duplicate's just-created golden is **indexed** → each
  creates its own golden; and
- MDM then **sticks**: re-submitting logs `Resource previously linked. Using
  existing link.` and never re-evaluates, so the duplicates stay split forever.

Reliable procedure (`scripts/run-mdm-linkage.sh`): submit the **authoritative
population first** (Synthea — distinct people, no races → base goldens), let it
index, **then** submit the duplicating copies (each participant), so each copy
matches its already-indexed golden:

```bash
scripts/run-mdm-linkage.sh --clear   # clear, then ordered submit
python3 scripts/verify-mdm-linkage.py
```

This is itself the MPI lesson (Known Lessons #5): linkage is as much about
*operational sequencing and indexing* as about matching rules.

## Rules-debugging notes (the other half of the lesson)

Getting matches at all took iterating `mdm-rules.json` (ADR 0010):
- **`birthDate` must use the `DATE` matcher**, not `STRING` — a string matcher
  on a date field silently never matches, so the full-match vector never forms.
- String matchers need `"exact": true` for exact equality.
- A bad `mdm_rules_json_location` (no `file:` prefix) crash-loops HAPI (3b.1).
- Verify scoring with `logging.level.ca.uhn.fhir.log.mdm_troubleshooting:
  DEBUG` (left on for MDM observability) — it logs the match `vector`/`score`
  (a clean three-way match logs `vector=15, score=4.0, MATCH`).

## Verification (`scripts/verify-mdm-linkage.py`)

Reports the golden-record count and the **sources-per-golden distribution**,
drills into a known three-way human (CAH-0001), and confirms sources are
intact. Golden records carry the tag
`http://hapifhir.io/fhir/NamingSystem/mdm-record-status|GOLDEN_RECORD` (note
**http**, not https). `$mdm-query-links` pages at ~100 — the script paginates
via `_offset`.

## Result — 2026-06-15 (PASS)

- **114 golden records** (113 Synthea + 1 for the non-twin Bahmni smoke-test
  patient; all 30 EHR twins collapsed into Synthea goldens).
- **Sources per golden: `{1: 89, 2: 20, 3: 5}`** — exactly **5 three-way**
  (Synthea + bahmni-central + openemr-cah, the deliberate overlap cohort) and
  **20 two-way**; 89 singletons (88 Synthea-only + 1 non-twin). 144 sources
  fully accounted for (89·1 + 20·2 + 5·3).
- CAH-0001's golden links Synthea + `bahmni-central` + `openemr-cah` sources.
- **Sources intact** — every `bahmni-central|BAH-000x` / `openemr-cah|CAH-000x`
  still resolves to exactly one source Patient (link-not-merge).

## Rollback

`POST /$mdm-clear` (Parameters: resourceType=Patient) removes all golden
records + links (async, ~1/sec — wait for the Patient count to return to the
source-only total). Sources are never touched by MDM, so nothing else to undo.
