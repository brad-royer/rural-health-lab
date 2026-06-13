#!/usr/bin/env python3
"""OpenEMR SMART Backend Services OAuth helper (Phase 3a, Gate K).

OpenEMR's FHIR API is OAuth2-gated and offers no password grant - only
client_credentials (asymmetric, private_key_jwt) and authorization_code. This
module does the backend-services dance so the seeder (3a.4) and verification
(3a.6) can get a bearer token non-interactively:

  1. generate an RSA keypair (once; stored gitignored under scripts/.secrets/)
  2. register a confidential client (jwks inline, private_key_jwt)
  3. mint a signed client-assertion JWT and exchange it for an access token

JWTs are signed with `cryptography` directly (RS384), avoiding a PyJWT dep.

CLI:
  python3 scripts/openemr_oauth.py register   # keygen + register the client
  python3 scripts/openemr_oauth.py token      # print a fresh access token
"""
import argparse
import base64
import json
import os
import sys
import time
import urllib.request
import uuid

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

BASE = os.environ.get("OPENEMR_BASE", "https://192.168.1.189")
TOKEN_URL = f"{BASE}/oauth2/default/token"
REG_URL = f"{BASE}/oauth2/default/registration"
SCOPE = os.environ.get("OPENEMR_SCOPE",
                       "openid api:fhir system/Patient.read system/Patient.write")

SECRETS = os.path.join(os.path.dirname(__file__), ".secrets")
KEY_PATH = os.path.join(SECRETS, "openemr-client-key.pem")
CLIENT_PATH = os.path.join(SECRETS, "openemr-client.json")
KID = "rhl-cin-hie-1"

import ssl
_CTX = ssl.create_default_context()
_CTX.check_hostname = False
_CTX.verify_mode = ssl.CERT_NONE


def b64u(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def int_b64u(i: int) -> str:
    return b64u(i.to_bytes((i.bit_length() + 7) // 8, "big"))


def post(url, data, headers=None, form=False):
    if form:
        body = urllib.parse.urlencode(data).encode()
        ct = "application/x-www-form-urlencoded"
    else:
        body = json.dumps(data).encode()
        ct = "application/json"
    req = urllib.request.Request(url, data=body, method="POST",
                                 headers={"Content-Type": ct, "Accept": "application/json",
                                          **(headers or {})})
    try:
        with urllib.request.urlopen(req, context=_CTX, timeout=30) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


import urllib.parse  # noqa: E402 (after helpers, before use)


def load_key():
    with open(KEY_PATH, "rb") as f:
        return serialization.load_pem_private_key(f.read(), password=None)


def jwk_public(priv):
    n = priv.public_key().public_numbers()
    return {"kty": "RSA", "alg": "RS384", "use": "sig", "kid": KID,
            "n": int_b64u(n.n), "e": int_b64u(n.e)}


def sign_jwt(header, payload, priv):
    seg = b64u(json.dumps(header, separators=(",", ":")).encode()) + "." + \
          b64u(json.dumps(payload, separators=(",", ":")).encode())
    sig = priv.sign(seg.encode(), padding.PKCS1v15(), hashes.SHA384())
    return seg + "." + b64u(sig)


def cmd_register():
    os.makedirs(SECRETS, exist_ok=True)
    if not os.path.exists(KEY_PATH):
        priv = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        with open(KEY_PATH, "wb") as f:
            f.write(priv.private_bytes(serialization.Encoding.PEM,
                                       serialization.PrivateFormat.PKCS8,
                                       serialization.NoEncryption()))
        os.chmod(KEY_PATH, 0o600)
    priv = load_key()
    status, body = post(REG_URL, {
        "application_type": "private",
        "client_name": "rhl-cin-hie",
        "redirect_uris": ["https://localhost/callback"],
        "grant_types": ["client_credentials"],
        "token_endpoint_auth_method": "private_key_jwt",
        "contacts": ["lab@lab.example"],
        "scope": SCOPE,
        "jwks": {"keys": [jwk_public(priv)]},
    })
    print(f"register -> HTTP {status}")
    print(json.dumps(body, indent=2)[:800])
    if status in (200, 201) and body.get("client_id"):
        with open(CLIENT_PATH, "w") as f:
            json.dump({"client_id": body["client_id"], "kid": KID,
                       "registered": body}, f, indent=2)
        print(f"\nsaved client_id={body['client_id']} to {CLIENT_PATH}")
    else:
        sys.exit(1)


def get_token():
    priv = load_key()
    client_id = json.load(open(CLIENT_PATH))["client_id"]
    now = int(time.time())
    assertion = sign_jwt(
        {"alg": "RS384", "kid": KID, "typ": "JWT"},
        {"iss": client_id, "sub": client_id, "aud": TOKEN_URL,
         "jti": str(uuid.uuid4()), "iat": now, "exp": now + 300},
        priv)
    status, body = post(TOKEN_URL, {
        "grant_type": "client_credentials",
        "scope": SCOPE,
        "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
        "client_assertion": assertion,
    }, form=True)
    if status != 200 or "access_token" not in body:
        print(f"token -> HTTP {status}: {json.dumps(body)}", file=sys.stderr)
        sys.exit(1)
    return body["access_token"]


def cmd_token():
    print(get_token())


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("command", choices=["register", "token"])
    args = ap.parse_args()
    {"register": cmd_register, "token": cmd_token}[args.command]()
