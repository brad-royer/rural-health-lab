#!/usr/bin/env bash
#
# load-to-hub.sh — Load Synthea-generated FHIR R4 transaction bundles into
# the HAPI hub (http://localhost:8080/fhir).
#
# Phase 1.4 (issue #7): hub-only population load. See
# docs/runbooks/phase1-synthea.md for the full runbook, including why load
# order matters.
#
# LOAD ORDER (this is the whole point of this script, not an implementation
# detail):
#   1. System bundles first: hospitalInformation*.json and
#      practitionerInformation*.json. These contain the Organization,
#      Location, and Practitioner resources that patient bundles reference.
#   2. Patient bundles second: every other *.json in synthea/output/fhir/.
#      Each references Organization/Practitioner resources by fixed
#      reference (not urn:uuid, since those live in a different bundle/file)
#      — if the referenced resource doesn't exist yet in the hub, HAPI's
#      transaction processor will fail the whole bundle (FHIR R4 transaction
#      semantics: a transaction either fully succeeds or fully fails).
#
# This mirrors a real CIN/ACO onboarding flow: provider directory / endpoint
# directory data (Organization, Practitioner, Location — "reference data")
# must exist before patient attribution / clinical data ("transactional
# data") can be ingested. See docs/runbooks/phase1-synthea.md for the CMS
# Health Tech Ecosystem framing.
#
# Usage:
#   scripts/load-to-hub.sh
#
# Env overrides (all optional):
#   HUB_URL  - FHIR base URL of the hub (default: http://localhost:8080/fhir)

set -euo pipefail

HUB_URL="${HUB_URL:-http://localhost:8080/fhir}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FHIR_DIR="${REPO_ROOT}/synthea/output/fhir"

if [ ! -d "${FHIR_DIR}" ]; then
  echo "ERROR: ${FHIR_DIR} does not exist." >&2
  echo "Run scripts/generate-synthea.sh first." >&2
  exit 1
fi

# --- Step 0: confirm the hub is reachable ---------------------------------
echo "Checking hub at ${HUB_URL}/metadata ..."
code=$(curl -s -o /dev/null -w "%{http_code}" "${HUB_URL}/metadata")
if [ "${code}" != "200" ]; then
  echo "ERROR: hub did not respond 200 on /metadata (got ${code})." >&2
  echo "Is the compose stack up? (cd compose && docker compose up -d)" >&2
  exit 1
fi
echo "Hub is up."
echo ""

# --- Helper: POST a single bundle file as a transaction --------------------
post_bundle() {
  local file="$1"
  local name
  name="$(basename "${file}")"

  local tmp_body
  tmp_body="$(mktemp)"
  local http_code
  http_code=$(curl -s -o "${tmp_body}" -w "%{http_code}" \
    -X POST "${HUB_URL}" \
    -H "Content-Type: application/fhir+json" \
    -d @"${file}")

  # Diagnostic lines go to stderr so they print live to the terminal even
  # though the caller captures this function's stdout via $(...) to grab
  # the http_code. If these went to stdout, `tail -n1` inside the capture
  # would silently swallow every OK/FAIL line and any FAIL response body —
  # the user would see no per-file progress and no clue why a bundle failed
  # until the final summary counts.
  if [ "${http_code}" = "200" ] || [ "${http_code}" = "201" ]; then
    echo "  OK   ${name} -> HTTP ${http_code}" >&2
  else
    echo "  FAIL ${name} -> HTTP ${http_code}" >&2
    echo "  ---- response body (first 40 lines) ----" >&2
    head -n 40 "${tmp_body}" | sed 's/^/  /' >&2
    echo "  -----------------------------------------" >&2
  fi

  rm -f "${tmp_body}"

  # Only the http_code goes to stdout — this is what the caller captures.
  echo "${http_code}"
}

# --- Step 1: system bundles (hospital + practitioner) FIRST ---------------
echo "=== Step 1: loading system bundles (hospital/practitioner) ==="
shopt -s nullglob
system_files=(
  "${FHIR_DIR}"/hospitalInformation*.json
  "${FHIR_DIR}"/practitionerInformation*.json
)

if [ "${#system_files[@]}" -eq 0 ]; then
  echo "WARNING: no hospitalInformation*/practitionerInformation* bundles found in ${FHIR_DIR}"
  echo "Patient bundle loads below may fail if they reference Organizations/Practitioners"
  echo "that don't already exist in the hub."
fi

system_failures=0
for f in "${system_files[@]}"; do
  result_code="$(post_bundle "${f}")"
  if [ "${result_code}" != "200" ] && [ "${result_code}" != "201" ]; then
    system_failures=$((system_failures + 1))
  fi
done
echo ""

if [ "${system_failures}" -gt 0 ]; then
  echo "ERROR: ${system_failures} system bundle(s) failed to load." >&2
  echo "Refusing to continue to patient bundles — they will likely fail too" >&2
  echo "since the Organization/Practitioner resources they reference may be" >&2
  echo "missing. Investigate the FAIL output above before retrying." >&2
  exit 1
fi

# --- Step 2: patient bundles (everything else) -----------------------------
echo "=== Step 2: loading patient bundles ==="
patient_files=()
for f in "${FHIR_DIR}"/*.json; do
  base="$(basename "${f}")"
  case "${base}" in
    hospitalInformation*.json|practitionerInformation*.json)
      continue
      ;;
    *)
      patient_files+=("${f}")
      ;;
  esac
done

if [ "${#patient_files[@]}" -eq 0 ]; then
  echo "WARNING: no patient bundles found in ${FHIR_DIR}"
fi

patient_failures=0
patient_ok=0
for f in "${patient_files[@]}"; do
  result_code="$(post_bundle "${f}")"
  if [ "${result_code}" = "200" ] || [ "${result_code}" = "201" ]; then
    patient_ok=$((patient_ok + 1))
  else
    patient_failures=$((patient_failures + 1))
  fi
done
echo ""

echo "=== Summary ==="
echo "Patient bundles loaded OK: ${patient_ok}"
echo "Patient bundles failed:    ${patient_failures}"
echo ""

# --- Step 3: validation counts ---------------------------------------------
echo "=== Validation: resource counts on hub ==="
for resource in Patient Condition Organization Practitioner; do
  count_json=$(curl -s "${HUB_URL}/${resource}?_summary=count")
  total=$(echo "${count_json}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total','?'))" 2>/dev/null || echo "?")
  echo "  ${resource}: ${total}"
done

if [ "${patient_failures}" -gt 0 ]; then
  echo ""
  echo "Completed with ${patient_failures} failed patient bundle(s) — see FAIL lines above."
  exit 1
fi

echo ""
echo "Done."
