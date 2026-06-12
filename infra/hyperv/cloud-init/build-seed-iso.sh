#!/usr/bin/env bash
# Build the cloud-init NoCloud seed ISO for the Phase 2.1 central-hospital VM
# (docs/phase2-kickoff-prompt.md). Generates a dedicated SSH keypair on first
# run (reused on later runs), renders user-data.template.yaml, and writes
# everything to .generated/ (gitignored — contains a real private key).
#
# Requires: ssh-keygen, openssl, python3 + pycdlib (pip install --user pycdlib)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$DIR/.generated"
mkdir -p "$OUT_DIR"

if ! python3 -c "import pycdlib" >/dev/null 2>&1; then
  echo "pycdlib is required: python3 -m pip install --user pycdlib" >&2
  exit 1
fi

KEY_PATH="$OUT_DIR/id_ed25519_central-hospital"
if [[ ! -f "$KEY_PATH" ]]; then
  ssh-keygen -t ed25519 -N "" -C "rhl-central-hospital" -f "$KEY_PATH" -q
fi
PUBKEY="$(cat "$KEY_PATH.pub")"

PASSWORD="$(openssl rand -base64 12)"
PASSHASH="$(openssl passwd -6 "$PASSWORD")"

# Escape sed metacharacters in the replacement text.
esc() { printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'; }

sed -e "s|__SSH_AUTHORIZED_KEY__|$(esc "$PUBKEY")|" \
    -e "s|__PASSWORD_HASH__|$(esc "$PASSHASH")|" \
    "$DIR/user-data.template.yaml" > "$OUT_DIR/user-data"

cp "$DIR/meta-data" "$OUT_DIR/meta-data"

python3 "$DIR/build_seed_iso.py" "$OUT_DIR/user-data" "$OUT_DIR/meta-data" "$OUT_DIR/seed.iso"

cat <<EOF

Seed ISO:         $OUT_DIR/seed.iso
SSH private key:  $KEY_PATH
SSH user:         ubuntu
Console password (SSH password auth is disabled; local console only):
  $PASSWORD

Pass the seed ISO path to infra/hyperv/New-CentralHospitalVM.ps1 -SeedIsoPath.
From Windows, this WSL path is reachable as a UNC path, e.g.:
  \\\\wsl.localhost\\<distro-name>\\home\\bradr\\projects\\rural-health-lab\\infra\\hyperv\\cloud-init\\.generated\\seed.iso
or copy seed.iso to a local Windows path (e.g. D:\\ISOs\\) first.
EOF
