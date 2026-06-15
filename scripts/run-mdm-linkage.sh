#!/usr/bin/env bash
# Ordered MDM linkage submit (Phase 3b.2).
#
# Naive bulk `$mdm-submit` of the whole population does NOT collapse duplicates:
# all resources process at once, so a duplicate's candidate search runs before
# the other duplicate's just-created golden is indexed -> each makes its own
# golden, and MDM then sticks ("Resource previously linked. Using existing
# link.") so re-submits never fix it. The reliable procedure is ORDERED:
# submit the authoritative population first (distinct people -> base goldens,
# no races), let it index, THEN submit the duplicating copies so each matches
# its already-indexed golden.
#
# Usage:  scripts/run-mdm-linkage.sh [--clear]
set -euo pipefail
HIE="${HIE:-http://localhost:8080/fhir}"
SYNTHEA='identifier=https://github.com/synthetichealth/synthea|'
PARTICIPANTS=(
  'identifier=https://lab.example/identifiers/bahmni-central|'
  'identifier=https://lab.example/identifiers/openemr-cah|'
)

submit() {  # $1 = criteria
  curl -s -X POST "$HIE/Patient/\$mdm-submit" -H "Content-Type: application/fhir+json" \
    -d "{\"resourceType\":\"Parameters\",\"parameter\":[{\"name\":\"criteria\",\"valueString\":\"$1\"}]}" \
    | python3 -c "import json,sys;print('  submitted:',[p['valueDecimal'] for p in json.load(sys.stdin)['parameter']][0])"
}
patient_count() {
  curl -s -H "Cache-Control: no-cache" "$HIE/Patient?_summary=count" \
    | python3 -c "import json,sys;print(json.load(sys.stdin)['total'])"
}
wait_stable() {  # wait until Patient count holds steady (processing settled)
  local prev=-1 stable=0 c
  for _ in $(seq 1 60); do
    c=$(patient_count)
    if [ "$c" = "$prev" ]; then stable=$((stable+1)); else stable=0; fi
    prev=$c; [ "$stable" -ge 4 ] && break; sleep 6
  done
  echo "  Patient count settled at: $c"
}

if [ "${1:-}" = "--clear" ]; then
  echo "== clearing existing MDM links/goldens (slow, ~1/sec) =="
  curl -s -X POST "$HIE/\$mdm-clear" -H "Content-Type: application/fhir+json" \
    -d '{"resourceType":"Parameters","parameter":[{"name":"resourceType","valueString":"Patient"}]}' -o /dev/null
  wait_stable
fi

echo "== phase 1: authoritative population (Synthea) -> base goldens =="
submit "$SYNTHEA"; wait_stable

echo "== phase 2: participant copies -> match into existing goldens =="
for crit in "${PARTICIPANTS[@]}"; do submit "$crit"; wait_stable; done

echo "== done. Verify with: python3 scripts/verify-mdm-linkage.py =="
