#!/usr/bin/env python3
"""Measure end-to-end CMS encounter-notification latency (Phase 3b.4).

Creates a patient + encounter in a participant EHR (reusing the 3a.6 EHR
backends), then times the full path:

    encounter created in EHR
      --(participant Mirth poll, ~60s)-->  Encounter in HAPI
      --(rest-hook Subscription, ~seconds)-->  subscriber receives

Reports the EHR->HIE leg (Mirth-poll-bound) and the HIE->subscriber leg
(subscription delivery), plus the total, against the (generous) CMS 24h SLA.
The lesson (Known Lessons #1): the SLA is trivially met, but latency is bounded
by the weakest-cadence hop (Mirth polling), not the subscription.

Usage:  python3 scripts/measure-notification-latency.py [--ehr openemr|bahmni]
"""
import argparse
import datetime
import json
import ssl
import subprocess
import sys
import time
import urllib.parse
import urllib.request

from ehr_backends import BACKENDS

HIE = "http://localhost:8080/fhir"
SYNTHEA = "https://github.com/synthetichealth/synthea"
SUBSCRIBER_CONTAINER = "hie-subscriber"
DEFAULTS = {
    "bahmni": ("https://lab.example/identifiers/bahmni-central",
               "https://lab.example/identifiers/bahmni-central/encounter"),
    "openemr": ("https://lab.example/identifiers/openemr-cah",
                "https://lab.example/identifiers/openemr-cah/encounter"),
}
_CTX = ssl.create_default_context()
_CTX.check_hostname = False
_CTX.verify_mode = ssl.CERT_NONE


def hie(method, path):
    r = urllib.request.Request(HIE + path, method=method,
                               headers={"Accept": "application/fhir+json", "Cache-Control": "no-cache"})
    with urllib.request.urlopen(r, context=_CTX, timeout=30) as resp:
        raw = resp.read()
        return json.loads(raw) if raw.strip() else {}


def now():
    return datetime.datetime.now(datetime.timezone.utc)


def subscriber_recv_time(hapi_enc_id, since="3m"):
    """Parse the subscriber's RECV timestamp for a given HAPI Encounter id."""
    out = subprocess.run(["docker", "logs", SUBSCRIBER_CONTAINER, "--since", since],
                         capture_output=True, text=True).stdout + \
          subprocess.run(["docker", "logs", SUBSCRIBER_CONTAINER, "--since", since],
                         capture_output=True, text=True).stderr
    for line in out.splitlines():
        if f"Encounter/{hapi_enc_id}" in line and line.startswith("RECV "):
            ts = line.split()[1]
            return datetime.datetime.fromisoformat(ts)
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--ehr", choices=list(BACKENDS), default="openemr")
    ap.add_argument("--timeout", type=int, default=180)
    args = ap.parse_args()
    psys, esys = DEFAULTS[args.ehr]
    backend = BACKENDS[args.ehr]()
    mrn = "NOTIFY-" + time.strftime("%Y%m%d%H%M%S", time.gmtime())
    print(f"EHR={backend.name}  MRN={mrn}\n")

    donor = hie("GET", f"/Patient?identifier={urllib.parse.quote(SYNTHEA + '|', safe='')}&_sort=family&_count=1")["entry"][0]["resource"]
    handle = backend.register_patient(donor, mrn)
    print("[1] patient registered; waiting for it to reach HIE before the encounter...")
    deadline = time.time() + args.timeout
    while time.time() < deadline:
        if hie("GET", f"/Patient?identifier={urllib.parse.quote(psys + '|' + mrn, safe='')}&_summary=count").get("total"):
            break
        time.sleep(5)

    t_created = now()
    enc_value = backend.create_encounter(handle)
    print(f"[2] encounter created in {backend.name} at {t_created.isoformat()} (value {enc_value})")

    # wait for it to land in HAPI (via the participant Mirth)
    hapi_enc = None
    while time.time() < deadline and not hapi_enc:
        b = hie("GET", f"/Encounter?identifier={urllib.parse.quote(esys + '|' + enc_value, safe='')}")
        if b.get("total"):
            hapi_enc = b["entry"][0]["resource"]["id"]
            t_in_hapi = now()
        else:
            time.sleep(5)
    if not hapi_enc:
        print("FAIL: encounter never reached HAPI"); backend.delete(handle, enc_value); sys.exit(1)
    print(f"[3] Encounter/{hapi_enc} in HIE at {t_in_hapi.isoformat()}")

    # wait for the subscriber to receive the notification
    t_notified = None
    while time.time() < deadline and not t_notified:
        t_notified = subscriber_recv_time(hapi_enc)
        if not t_notified:
            time.sleep(3)
    if not t_notified:
        print("FAIL: subscriber never received the notification"); backend.delete(handle, enc_value); sys.exit(1)

    ehr_to_hie = (t_in_hapi - t_created).total_seconds()
    hie_to_sub = (t_notified - t_in_hapi).total_seconds()
    total = (t_notified - t_created).total_seconds()
    print(f"[4] subscriber notified at {t_notified.isoformat()}\n")
    print(f"  EHR -> HIE (participant Mirth poll): {ehr_to_hie:.1f}s")
    print(f"  HIE -> subscriber (Subscription):    {hie_to_sub:.1f}s")
    print(f"  TOTAL end-to-end:                    {total:.1f}s  (CMS SLA: 24h = 86400s)")
    print(f"  -> SLA met with {86400 - total:.0f}s to spare; latency dominated by the Mirth poll cadence.")

    backend.delete(handle, enc_value)
    encs = hie("GET", f"/Encounter?identifier={urllib.parse.quote(esys + '|' + enc_value, safe='')}")
    if encs.get("entry"):
        hie("DELETE", f"/Encounter/{encs['entry'][0]['resource']['id']}")
    pats = hie("GET", f"/Patient?identifier={urllib.parse.quote(psys + '|' + mrn, safe='')}")
    if pats.get("entry"):
        hie("DELETE", f"/Patient/{pats['entry'][0]['resource']['id']}")
    print("\n[5] cleaned up. PASS: notification path verified end-to-end.")


if __name__ == "__main__":
    main()
