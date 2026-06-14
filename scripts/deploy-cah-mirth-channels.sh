#!/usr/bin/env bash
# Import + deploy the CAH Mirth channels (Phase 3a.5) to the CAH's Mirth on
# Host #2 (192.168.1.189:8443). Idempotent (PUT override + redeploy); the
# channels' conditional upserts absorb the full resync a redeploy triggers.
# Mirrors scripts/deploy-mirth-channels.sh but targets the CAH instance.
set -euo pipefail

MIRTH_URL="${MIRTH_URL:-https://192.168.1.189:8443}"
MIRTH_USER="${MIRTH_USER:-admin}"
MIRTH_PASSWORD="${MIRTH_PASSWORD:-admin}"
CHANNEL_DIR="$(cd "$(dirname "$0")/../compose/cah-mirth/channels" && pwd)"

api() { curl -sk -u "$MIRTH_USER:$MIRTH_PASSWORD" -H "X-Requested-With: OpenAPI" "$@"; }

for xml in "$CHANNEL_DIR"/*.xml; do
    id=$(grep -oPm1 '(?<=<id>)[^<]+' "$xml")
    name=$(grep -oPm1 '(?<=<name>)[^<]+' "$xml")
    echo "== $name ($id)"
    code=$(api -X PUT "$MIRTH_URL/api/channels/$id?override=true" \
        -H "Content-Type: application/xml" --data-binary "@$xml" -o /dev/null -w "%{http_code}")
    [ "$code" = "200" ] || { echo "   import FAILED: HTTP $code"; exit 1; }
    code=$(api -X POST "$MIRTH_URL/api/channels/$id/_deploy" -o /dev/null -w "%{http_code}")
    [ "$code" = "204" ] || { echo "   deploy FAILED: HTTP $code"; exit 1; }
    echo "   imported + deployed"
done

echo
echo "Channel statistics:"
for xml in "$CHANNEL_DIR"/*.xml; do
    id=$(grep -oPm1 '(?<=<id>)[^<]+' "$xml")
    name=$(grep -oPm1 '(?<=<name>)[^<]+' "$xml")
    stats=$(api "$MIRTH_URL/api/channels/$id/statistics" \
        | sed -n 's/.*<\(received\|sent\|error\)>\([0-9]*\)<.*/\1=\2/p' | paste -sd' ' -)
    echo "  $name: $stats"
done
