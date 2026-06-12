#!/usr/bin/env python3
"""Seed the Bahmni central-hospital patient panel (increment 2.3, ADR 0003).

Registers the patients pinned in scripts/seed-panel-manifest.json into
Bahmni's OpenMRS via its FHIR2 R4 API. Idempotent and re-runnable: each
manifest entry carries a fixed Bahmni MRN (BAH-NNNN), and the script skips
any MRN that already exists. Demographics come from the manifest (originally
a Synthea subset); no Synthea/HAPI identifier or UUID is ever sent to Bahmni
(Gate B / ADR 0003).

Usage (from WSL2, repo root):
    python3 scripts/seed-bahmni-panel.py [--base-url https://192.168.1.230]

Credentials via BAHMNI_USER / BAHMNI_PASSWORD env vars; defaults are the
well-known Bahmni lab defaults (synthetic data only — change before anything
production-like).
"""

import argparse
import base64
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

MANIFEST = os.path.join(os.path.dirname(__file__), "seed-panel-manifest.json")
# Bahmni's required primary identifier type (name is stable across installs;
# the UUID differs per install, so we look it up at runtime).
IDENTIFIER_TYPE_NAME = "Patient Identifier"


def make_opener(base_url, user, password):
    # Bahmni ships a self-signed cert; this lab talks to it over a private LAN.
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    auth = base64.b64encode(f"{user}:{password}".encode()).decode()

    def request(method, path, body=None):
        req = urllib.request.Request(
            base_url + path,
            data=json.dumps(body).encode() if body is not None else None,
            method=method,
            headers={
                "Authorization": f"Basic {auth}",
                "Accept": "application/fhir+json, application/json",
                **({"Content-Type": "application/fhir+json"} if body else {}),
            },
        )
        with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
            return resp.status, json.load(resp)

    return request


def identifier_type_uuid(request):
    _, data = request(
        "GET",
        "/openmrs/ws/rest/v1/patientidentifiertype?v=custom:(uuid,name)",
    )
    for t in data["results"]:
        if t["name"] == IDENTIFIER_TYPE_NAME:
            return t["uuid"]
    sys.exit(f"ERROR: identifier type {IDENTIFIER_TYPE_NAME!r} not found in Bahmni")


def mrn_exists(request, mrn):
    q = urllib.parse.quote(mrn)
    _, bundle = request(
        "GET", f"/openmrs/ws/fhir2/R4/Patient?identifier={q}&_summary=count"
    )
    return bundle.get("total", 0) > 0


def ensure_address(request, entry):
    """Repair the street address via the OpenMRS REST API.

    OpenMRS's FHIR2 module drops Address.line on Patient create (observed on
    openmrs:1.1.3 / FHIR2 R4: city/state/zip persist, address1 stays null and
    the address is left non-preferred), so the street line has to be written
    through the REST person API instead. Idempotent: no-op when address1
    already matches the manifest.
    """
    mrn = urllib.parse.quote(entry["mrn"])
    _, data = request(
        "GET",
        f"/openmrs/ws/rest/v1/patient?q={mrn}"
        "&v=custom:(person:(uuid,addresses:(uuid,address1,address2,preferred)))",
    )
    if not data["results"]:
        return "missing"
    person = data["results"][0]["person"]
    line = entry["address"]["line"]
    want = {
        "address1": line[0] if line else None,
        "address2": line[1] if len(line) > 1 else None,
        "preferred": True,
    }
    addr = person["addresses"][0] if person["addresses"] else None
    if addr and all(addr.get(k) == v for k, v in want.items()):
        return "ok"
    request(
        "POST",
        f"/openmrs/ws/rest/v1/person/{person['uuid']}/address"
        + (f"/{addr['uuid']}" if addr else ""),
        want,
    )
    return "fixed"


def fhir_patient(entry, id_type_uuid):
    return {
        "resourceType": "Patient",
        "identifier": [
            {
                "use": "official",
                "type": {
                    "coding": [{"code": id_type_uuid}],
                    "text": IDENTIFIER_TYPE_NAME,
                },
                "value": entry["mrn"],
            }
        ],
        "name": [
            {
                "use": "official",
                "family": entry["family"],
                "given": entry["given"],
            }
        ],
        "gender": entry["gender"],
        "birthDate": entry["birthDate"],
        "address": [
            {
                "line": entry["address"]["line"],
                "city": entry["address"]["city"],
                "state": entry["address"]["state"],
                "postalCode": entry["address"]["postalCode"],
                "country": entry["address"]["country"],
            }
        ],
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--base-url", default="https://192.168.1.230")
    args = ap.parse_args()

    user = os.environ.get("BAHMNI_USER", "superman")
    password = os.environ.get("BAHMNI_PASSWORD", "Admin123")
    request = make_opener(args.base_url.rstrip("/"), user, password)

    with open(MANIFEST) as f:
        patients = json.load(f)["patients"]

    id_type_uuid = identifier_type_uuid(request)
    created, skipped, failed = 0, 0, 0
    for entry in patients:
        mrn = entry["mrn"]
        try:
            if mrn_exists(request, mrn):
                action = "skip  "
                skipped += 1
            else:
                request(
                    "POST", "/openmrs/ws/fhir2/R4/Patient", fhir_patient(entry, id_type_uuid)
                )
                action = "create"
                created += 1
            addr = ensure_address(request, entry)
            print(f"  {action} {mrn}  {' '.join(entry['given'])} {entry['family']}  (address: {addr})")
        except urllib.error.HTTPError as e:
            print(f"  FAIL   {mrn}  HTTP {e.code}: {e.read().decode()[:500]}")
            failed += 1

    print(f"\ncreated={created} skipped={skipped} failed={failed} (manifest={len(patients)})")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
