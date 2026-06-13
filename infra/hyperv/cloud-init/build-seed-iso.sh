#!/usr/bin/env bash
# Build a cloud-init NoCloud seed ISO for a lab VM. Generates a dedicated SSH
# keypair on first run (reused on later runs), renders user-data.template.yaml
# with the given hostname, and writes everything to .generated/<hostname>/
# (gitignored — contains a real private key).
#
#   Usage: build-seed-iso.sh <hostname>        e.g. rhl-acquired-cah
#
# Requires: ssh-keygen, openssl, python3 + pycdlib (pip install --user pycdlib)
set -euo pipefail

HOSTNAME_ARG="${1:?usage: build-seed-iso.sh <hostname>  (e.g. rhl-acquired-cah)}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$DIR/.generated/$HOSTNAME_ARG"
mkdir -p "$OUT_DIR"

if ! python3 -c "import pycdlib" >/dev/null 2>&1; then
  echo "pycdlib is required: python3 -m pip install --user pycdlib" >&2
  exit 1
fi

KEY_PATH="$OUT_DIR/id_ed25519_${HOSTNAME_ARG}"
if [[ ! -f "$KEY_PATH" ]]; then
  ssh-keygen -t ed25519 -N "" -C "$HOSTNAME_ARG" -f "$KEY_PATH" -q
fi
PUBKEY="$(cat "$KEY_PATH.pub")"

PASSWORD="$(openssl rand -base64 12)"
PASSHASH="$(openssl passwd -6 "$PASSWORD")"

# Escape sed metacharacters in the replacement text.
esc() { printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'; }

sed -e "s|__SSH_AUTHORIZED_KEY__|$(esc "$PUBKEY")|" \
    -e "s|__PASSWORD_HASH__|$(esc "$PASSHASH")|" \
    -e "s|__HOSTNAME__|$(esc "$HOSTNAME_ARG")|" \
    "$DIR/user-data.template.yaml" > "$OUT_DIR/user-data"

# meta-data is trivial and host-specific; generate it inline.
printf 'instance-id: %s\nlocal-hostname: %s\n' "$HOSTNAME_ARG" "$HOSTNAME_ARG" \
    > "$OUT_DIR/meta-data"

python3 "$DIR/build_seed_iso.py" "$OUT_DIR/user-data" "$OUT_DIR/meta-data" "$OUT_DIR/seed.iso"

cat <<EOF

Seed ISO:         $OUT_DIR/seed.iso
SSH private key:  $KEY_PATH
SSH user:         ubuntu
Console password (SSH password auth is disabled; local console only):
  $PASSWORD

Pass the seed ISO to infra/hyperv/New-LabVM.ps1 -SeedIsoPath (copied to a
LOCAL path on the target Windows host). From Windows this WSL path is a UNC
path, e.g.:
  \\\\wsl.localhost\\<distro>\\home\\bradr\\projects\\rural-health-lab\\infra\\hyperv\\cloud-init\\.generated\\$HOSTNAME_ARG\\seed.iso
EOF
