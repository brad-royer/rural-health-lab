#!/usr/bin/env python3
"""HIE OAuth gateway (Phase 3b.6).

Fronts HAPI at the participant write boundary: validates the Keycloak-issued
Bearer JWT (RS256 signature via the realm JWKS, issuer, expiry) and reverse-
proxies valid requests to HAPI; everything else gets 401. Stock HAPI has no
turnkey OAuth, so this is the "fronting proxy" enforcement (Gate N / ADR 0012).
JWTs are verified with `cryptography` (no PyJWT).
"""
import base64
import json
import os
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives.asymmetric.rsa import RSAPublicNumbers

HAPI = os.environ.get("HAPI_BASE", "http://hapi-hub:8080")
ISSUER = os.environ.get("EXPECTED_ISSUER", "http://192.168.1.176:8090/realms/rural-health-hie")
JWKS_URL = os.environ.get("JWKS_URL",
                          "http://keycloak:8080/realms/rural-health-hie/protocol/openid-connect/certs")
_jwks = {}


def b64u(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def load_jwks():
    global _jwks
    with urllib.request.urlopen(JWKS_URL, timeout=10) as r:
        _jwks = {k["kid"]: k for k in json.load(r)["keys"]}


def verify(token):
    h_b64, p_b64, s_b64 = token.split(".")
    header = json.loads(b64u(h_b64))
    payload = json.loads(b64u(p_b64))
    jwk = _jwks.get(header.get("kid"))
    if not jwk:
        load_jwks()
        jwk = _jwks.get(header.get("kid"))
    if not jwk:
        raise ValueError("unknown signing key")
    pub = RSAPublicNumbers(int.from_bytes(b64u(jwk["e"]), "big"),
                           int.from_bytes(b64u(jwk["n"]), "big")).public_key()
    pub.verify(b64u(s_b64), (h_b64 + "." + p_b64).encode(), padding.PKCS1v15(), hashes.SHA256())
    if payload.get("iss") != ISSUER:
        raise ValueError(f"bad issuer {payload.get('iss')}")
    if payload.get("exp", 0) < time.time():
        raise ValueError("token expired")
    return payload


class Handler(BaseHTTPRequestHandler):
    def _deny(self, msg):
        b = json.dumps({"error": "unauthorized", "detail": msg}).encode()
        self.send_response(401)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _relay(self, code, body, ctype):
        self.send_response(code)
        if ctype:
            self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_request(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            self._deny("missing bearer token")
            return
        try:
            verify(auth[7:])
        except Exception as ex:
            self._deny(str(ex))
            return
        # forward to HAPI (token consumed at the boundary; not passed on)
        n = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(n) if n else None
        req = urllib.request.Request(HAPI + self.path, data=body, method=self.command)
        for hk in ("Content-Type", "Accept", "Prefer", "If-None-Exist", "Cache-Control"):
            v = self.headers.get(hk)
            if v:
                req.add_header(hk, v)
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                self._relay(r.status, r.read(), r.headers.get("Content-Type"))
        except urllib.error.HTTPError as e:
            self._relay(e.code, e.read(), e.headers.get("Content-Type"))

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = handle_request

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    load_jwks()
    print(f"HIE OAuth gateway on :8080 -> {HAPI} (issuer {ISSUER})", flush=True)
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
