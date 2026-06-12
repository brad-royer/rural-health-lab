#!/usr/bin/env bash
# Import and deploy every Mirth channel in compose/mirth/channels/ (increment
# 2.4, issue #13). Idempotent and re-runnable: import is a PUT with
# override=true keyed on the fixed channel id inside each XML, and redeploy
# triggers a full resync that the channels' conditional upserts absorb.
#
# Credentials default to Mirth's well-known initial admin login (synthetic
# lab only - change before anything production-like).
set -euo pipefail

MIRTH_URL="${MIRTH_URL:-https://localhost:8443}"
MIRTH_USER="${MIRTH_USER:-admin}"
MIRTH_PASSWORD="${MIRTH_PASSWORD:-admin}"
CHANNEL_DIR="$(cd "$(dirname "$0")/../compose/mirth/channels" && pwd)"

api() {
    curl -sk -u "$MIRTH_USER:$MIRTH_PASSWORD" -H "X-Requested-With: OpenAPI" "$@"
}

for xml in "$CHANNEL_DIR"/*.xml; do
    id=$(grep -oPm1 '(?<=<id>)[^<]+' "$xml")
    name=$(grep -oPm1 '(?<=<name>)[^<]+' "$xml")
    echo "== $name ($id)"

    code=$(api -X PUT "$MIRTH_URL/api/channels/$id?override=true" \
        -H "Content-Type: application/xml" --data-binary "@$xml" \
        -o /dev/null -w "%{http_code}")
    [ "$code" = "200" ] || { echo "   import FAILED: HTTP $code"; exit 1; }
    echo "   imported (HTTP $code)"

    code=$(api -X POST "$MIRTH_URL/api/channels/$id/_deploy" \
        -o /dev/null -w "%{http_code}")
    [ "$code" = "204" ] || { echo "   deploy FAILED: HTTP $code"; exit 1; }
    echo "   deployed (HTTP $code)"
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
