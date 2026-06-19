#!/usr/bin/env python3
"""Fetch the Keycloak-generated participant client secrets (Phase 3b.5).

The realm (compose/keycloak/realm-export.json) defines the participant
client_credentials clients but commits no secrets; Keycloak generates them on
import. This reads them via the admin API and writes them to
scripts/.secrets/keycloak-clients.json (gitignored) for the Mirths to use in
3b.6. Re-run after a clean Keycloak rebuild (secrets regenerate).

Usage:  python3 scripts/fetch_keycloak_secrets.py
"""
import json
import os
import urllib.parse
import urllib.request

KC = os.environ.get("KC_URL", "http://localhost:8090")
REALM = "rural-health-hie"
ADMIN_USER = os.environ.get("KEYCLOAK_ADMIN_USERNAME", "admin")
ADMIN_PASS = os.environ.get("KEYCLOAK_ADMIN_PASSWORD", "admin")
CLIENTS = ["central-hospital-mirth", "acquired-cah-mirth"]
SECRETS = os.path.join(os.path.dirname(__file__), ".secrets")
OUT = os.path.join(SECRETS, "keycloak-clients.json")


def post_form(url, data):
    body = urllib.parse.urlencode(data).encode()
    with urllib.request.urlopen(urllib.request.Request(url, data=body), timeout=30) as r:
        return json.load(r)


def get(url, token):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def main():
    token = post_form(f"{KC}/realms/master/protocol/openid-connect/token", {
        "grant_type": "password", "client_id": "admin-cli",
        "username": ADMIN_USER, "password": ADMIN_PASS})["access_token"]
    result = {"realm": REALM,
              "token_url": f"{KC}/realms/{REALM}/protocol/openid-connect/token",
              "clients": {}}
    for cid in CLIENTS:
        found = get(f"{KC}/admin/realms/{REALM}/clients?clientId={cid}", token)
        iid = found[0]["id"]
        secret = get(f"{KC}/admin/realms/{REALM}/clients/{iid}/client-secret", token)["value"]
        result["clients"][cid] = secret
    os.makedirs(SECRETS, exist_ok=True)
    with open(OUT, "w") as f:
        json.dump(result, f, indent=2)
    os.chmod(OUT, 0o600)
    print(f"wrote {OUT}")
    for cid in CLIENTS:
        print(f"  {cid}: secret {result['clients'][cid][:6]}…")


if __name__ == "__main__":
    main()
