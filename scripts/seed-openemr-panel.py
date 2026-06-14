#!/usr/bin/env python3
"""Seed the acquired-CAH (OpenEMR) patient panel (Phase 3a.4, ADR 0008).

Registers the patients pinned in scripts/openemr-seed-manifest.json into
OpenEMR via its FHIR R4 API, authenticating with a SMART Backend Services
token (scripts/openemr_oauth.py). Idempotent and re-runnable: each entry has
a fixed CAH MRN (CAH-NNNN); existing MRNs are skipped. Demographics come from
the manifest (a Synthea subset); no Synthea/HAPI/Bahmni identifier is sent.

OpenEMR seam (Gate K finding): its FHIR Patient create *ignores* a
caller-supplied identifier and auto-assigns its own (pubpid). To pin the CAH
MRN, this seeder creates the patient via FHIR, then sets `pubpid=CAH-NNNN` in
patient_data keyed by the returned uuid (a small DB write over SSH) - after
which OpenEMR's FHIR exposes and searches that identifier. The openemr-cah
*system* URI itself is stamped HIE-side by the CAH Mirth in 3a.5 (ADR 0008 /
0003 lineage).

Env: OPENEMR_BASE, plus EHR_SSH_KEY / EHR_HOST / EHR_DB_CONTAINER for the
pubpid write (defaults target rhl-acquired-cah).

Usage:  python3 scripts/seed-openemr-panel.py
"""
import json
import os
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

import openemr_oauth as oauth

SSH_KEY = os.environ.get(
    "EHR_SSH_KEY",
    os.path.join(os.path.dirname(__file__), "..", "infra", "hyperv", "cloud-init",
                 ".generated", "rhl-acquired-cah", "id_ed25519_rhl-acquired-cah"))
EHR_HOST = os.environ.get("EHR_HOST", "ubuntu@192.168.1.189")
EHR_DB_CONTAINER = os.environ.get("EHR_DB_CONTAINER", "openemr-mysql-1")


def set_pubpids(mrn_by_uuid):
    """Set patient_data.pubpid = CAH-NNNN for freshly created patients,
    keyed by FHIR uuid, in one batched DB statement over SSH."""
    stmts = []
    for uuid_dashed, mrn in mrn_by_uuid.items():
        h = uuid_dashed.replace("-", "")
        stmts.append(f"UPDATE patient_data SET pubpid='{mrn}' WHERE uuid=UNHEX('{h}');")
    sql = " ".join(stmts)
    cmd = ["ssh", "-i", SSH_KEY, "-o", "StrictHostKeyChecking=accept-new", EHR_HOST,
           f"docker exec -i {EHR_DB_CONTAINER} mariadb -uroot -proot openemr"]
    subprocess.run(cmd, input=sql.encode(), check=True)

BASE = os.environ.get("OPENEMR_BASE", "https://192.168.1.189")
FHIR = f"{BASE}/apis/default/fhir"
MANIFEST = os.path.join(os.path.dirname(__file__), "openemr-seed-manifest.json")

_CTX = ssl.create_default_context()
_CTX.check_hostname = False
_CTX.verify_mode = ssl.CERT_NONE


def req(method, url, token, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/fhir+json",
        **({"Content-Type": "application/fhir+json"} if body else {}),
    })
    try:
        with urllib.request.urlopen(r, context=_CTX, timeout=30) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw.strip() else {})
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def exists(token, mrn):
    q = urllib.parse.quote(mrn)
    status, bundle = req("GET", f"{FHIR}/Patient?identifier={q}", token)
    return status == 200 and bundle.get("total", 0) > 0


def fhir_patient(entry):
    # OpenEMR ignores a supplied identifier on create; pubpid is set afterward.
    addr = entry["address"]
    return {
        "resourceType": "Patient",
        "name": [{"use": "official", "family": entry["family"], "given": entry["given"]}],
        "gender": entry["gender"],
        "birthDate": entry["birthDate"],
        "address": [{k: addr[k] for k in ("line", "city", "state", "postalCode", "country") if k in addr}],
    }


def created_uuid(status, body, resp_headers):
    # OpenEMR's FHIR create returns 201 with a custom body {"pid","uuid"}
    # (not a FHIR resource). Fall back to id / Location for spec-compliant
    # servers.
    if body.get("uuid"):
        return body["uuid"]
    if body.get("id"):
        return body["id"]
    loc = resp_headers.get("Location") or resp_headers.get("location", "")
    return loc.rstrip("/").split("/")[-1] if loc else None


def post_patient(token, entry):
    data = json.dumps(fhir_patient(entry)).encode()
    r = urllib.request.Request(f"{FHIR}/Patient", data=data, method="POST", headers={
        "Authorization": f"Bearer {token}", "Accept": "application/fhir+json",
        "Content-Type": "application/fhir+json"})
    with urllib.request.urlopen(r, context=_CTX, timeout=30) as resp:
        raw = resp.read()
        body = json.loads(raw) if raw.strip() else {}
        return resp.status, body, dict(resp.headers)


def main():
    token = oauth.get_token()
    patients = json.load(open(MANIFEST))["patients"]
    created = skipped = failed = 0
    new_pubpids = {}
    for e in patients:
        mrn = e["mrn"]
        try:
            if exists(token, mrn):
                print(f"  skip   {mrn}  (already registered)")
                skipped += 1
                continue
            status, body, headers = post_patient(token, e)
            uuid = created_uuid(status, body, headers)
            if status in (200, 201) and uuid:
                new_pubpids[uuid] = mrn
                print(f"  create {mrn}  {' '.join(e['given'])} {e['family']}  -> HTTP {status} ({uuid})")
                created += 1
            else:
                print(f"  FAIL   {mrn}  HTTP {status}: no uuid; body={json.dumps(body)[:200]}")
                failed += 1
        except Exception as ex:
            print(f"  FAIL   {mrn}  {ex}")
            failed += 1

    if new_pubpids:
        print(f"\nsetting pubpid (CAH MRN) on {len(new_pubpids)} new patient(s) via DB...")
        set_pubpids(new_pubpids)

    print(f"\ncreated={created} skipped={skipped} failed={failed} (manifest={len(patients)})")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
