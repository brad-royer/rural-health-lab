#!/usr/bin/env python3
"""Lightweight HIE subscription receiver (Phase 3b.3).

Receives HAPI rest-hook notifications for the CMS "encounter notification
within 24h" simulation and logs a UTC receipt timestamp + the delivered
resource id, so 3b.4 can measure end-to-end latency from docker logs. Stdlib
only; not a real endpoint (no auth/persistence) — that's the production delta.
"""
import datetime
import json
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def _respond(self, code=200):
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(n) if n else b""
        ts = datetime.datetime.now(datetime.timezone.utc).isoformat()
        rid = "(empty payload / id-only notification)"
        try:
            r = json.loads(body)
            rid = f"{r.get('resourceType')}/{r.get('id')}"
        except Exception:
            pass
        print(f"RECV {ts} path={self.path} {rid}", flush=True)
        self._respond(200)

    # HAPI rest-hook with a payload delivers via PUT (RESTful update style),
    # not POST — handle both.
    do_PUT = do_POST

    def do_GET(self):  # health check
        self._respond(200)

    def log_message(self, *a):  # silence default access logging
        pass


if __name__ == "__main__":
    print("HIE subscriber listening on :9000", flush=True)
    HTTPServer(("0.0.0.0", 9000), Handler).serve_forever()
