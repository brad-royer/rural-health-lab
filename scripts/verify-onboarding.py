#!/usr/bin/env python3
"""Verify a participant EHR -> Mirth -> HIE onboarding round trip (increment 2.5).

The Phase 2 closeout validation and the Phase 3 acceptance-test template:
everything participant-specific is an env var (defaults = Bahmni, the central
hospital). The script:

  1. Records HIE baselines (total / Synthea-population / participant counts).
  2. Picks a deterministic "donor" Synthea patient from the HIE and registers
     the *same human* in the participant EHR under a fresh, unique MRN
     (VRFY-<UTC timestamp>) -- per ADR 0003, demographics overlap,
     identifiers are disjoint.
  3. Creates an encounter (visit) for that patient in the EHR.
  4. Polls the HIE until both arrive via Mirth (default timeout 180s),
     asserting the participant identifier systems (ADR 0003/0005) and that
     the encounter's subject was resolved to the HIE patient by identifier.
  5. Asserts the Synthea population count is UNCHANGED (additive, no
     collision) and calls out the resulting duplicate-person condition as
     the intentional ADR 0003 artifact -- not a bug.
  6. Cleans up (void in EHR, delete in HIE) unless --keep is given.

Exit code 0 = all assertions passed. Any failure exits 1 with the reason.

Usage:  python3 scripts/verify-onboarding.py [--keep] [--timeout SECONDS]
"""

import argparse
import base64
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# Participant (EHR) parameters -- override for Phase 3 / other participants.
EHR_FHIR = os.environ.get("EHR_FHIR_BASE", "https://192.168.1.230/openmrs/ws/fhir2/R4")
EHR_REST = os.environ.get("EHR_REST_BASE", "https://192.168.1.230/openmrs/ws/rest/v1")
EHR_USER = os.environ.get("EHR_USER", "superman")
EHR_PASSWORD = os.environ.get("EHR_PASSWORD", "Admin123")
EHR_IDENTIFIER_TYPE = os.environ.get("EHR_IDENTIFIER_TYPE", "Patient Identifier")
PATIENT_SYSTEM = os.environ.get(
    "PATIENT_SYSTEM", "https://lab.example/identifiers/bahmni-central"
)
ENCOUNTER_SYSTEM = os.environ.get(
    "ENCOUNTER_SYSTEM", "https://lab.example/identifiers/bahmni-central/encounter"
)

# HIE parameters.
HIE_FHIR = os.environ.get("HIE_FHIR_BASE", "http://localhost:8080/fhir")
SYNTHEA_SYSTEM = os.environ.get(
    "SYNTHEA_SYSTEM", "https://github.com/synthetichealth/synthea"
)


def fail(msg):
    print(f"\nFAIL: {msg}")
    sys.exit(1)


def make_requester(user=None, password=None, insecure=False):
    ctx = None
    if insecure:
        # Lab EHRs ship self-signed certs; production delta in the runbook.
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    auth = None
    if user is not None:
        auth = base64.b64encode(f"{user}:{password}".encode()).decode()

    def request(method, url, body=None):
        req = urllib.request.Request(
            url,
            data=json.dumps(body).encode() if body is not None else None,
            method=method,
            headers={
                **({"Authorization": f"Basic {auth}"} if auth else {}),
                "Accept": "application/fhir+json, application/json",
                # HAPI reuses identical search results for ~60s by default;
                # consecutive runs would read stale counts without this.
                "Cache-Control": "no-cache",
                **({"Content-Type": "application/fhir+json"} if body else {}),
            },
        )
        with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
            raw = resp.read()
            return resp.status, json.loads(raw) if raw.strip() else {}

    return request


ehr = make_requester(EHR_USER, EHR_PASSWORD, insecure=True)
hie = make_requester()


def hie_count(resource, identifier_prefix=None):
    q = f"{HIE_FHIR}/{resource}?_summary=count"
    if identifier_prefix:
        q += "&identifier=" + urllib.parse.quote(identifier_prefix, safe="")
    _, bundle = hie("GET", q)
    return bundle.get("total", 0)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--keep", action="store_true", help="skip cleanup")
    ap.add_argument("--timeout", type=int, default=int(os.environ.get("TIMEOUT_SECONDS", 180)))
    args = ap.parse_args()

    mrn = "VRFY-" + time.strftime("%Y%m%d%H%M%S", time.gmtime())
    print(f"Verification MRN: {mrn} (unique per run)\n")

    # --- 1. Baselines -------------------------------------------------------
    base_total = hie_count("Patient")
    base_synthea = hie_count("Patient", SYNTHEA_SYSTEM + "|")
    base_participant = hie_count("Patient", PATIENT_SYSTEM + "|")
    print(f"[1/6] HIE baselines: total={base_total}, "
          f"synthea={base_synthea}, participant={base_participant}")

    # --- 2. Donor + EHR registration ---------------------------------------
    _, donors = hie("GET", f"{HIE_FHIR}/Patient?identifier="
                    + urllib.parse.quote(SYNTHEA_SYSTEM + "|", safe="")
                    + "&_sort=family&_count=1")
    if not donors.get("entry"):
        fail("no Synthea-population patient found in the HIE to act as donor")
    donor = donors["entry"][0]["resource"]
    name = next(n for n in donor["name"] if n.get("use", "official") == "official")
    addr = (donor.get("address") or [{}])[0]
    print(f"[2/6] Donor (same human, per ADR 0003): "
          f"{' '.join(name.get('given', []))} {name.get('family')} "
          f"b. {donor.get('birthDate')} (HIE Patient/{donor['id']})")

    _, types = ehr("GET", f"{EHR_REST}/patientidentifiertype?v=custom:(uuid,name)")
    type_uuid = next(
        (t["uuid"] for t in types["results"] if t["name"] == EHR_IDENTIFIER_TYPE), None
    )
    if not type_uuid:
        fail(f"identifier type {EHR_IDENTIFIER_TYPE!r} not found in the EHR")

    status, created = ehr("POST", f"{EHR_FHIR}/Patient", {
        "resourceType": "Patient",
        "identifier": [{
            "use": "official",
            "type": {"coding": [{"code": type_uuid}], "text": EHR_IDENTIFIER_TYPE},
            "value": mrn,
        }],
        "name": [{"use": "official",
                  "family": name.get("family"), "given": name.get("given", [])}],
        "gender": donor.get("gender"),
        "birthDate": donor.get("birthDate"),
        "address": [{k: addr[k] for k in
                     ("line", "city", "state", "postalCode", "country") if k in addr}],
    })
    ehr_patient_uuid = created["id"]

    # OpenMRS FHIR2 drops Address.line on create (2.3 runbook gotcha #3);
    # repair via REST so the duplicate-person demographics fully match.
    if addr.get("line"):
        _, pdata = ehr("GET", f"{EHR_REST}/patient/{ehr_patient_uuid}"
                       "?v=custom:(person:(uuid,addresses:(uuid)))")
        addrs = pdata["person"]["addresses"]
        ehr("POST", f"{EHR_REST}/person/{ehr_patient_uuid}/address"
            + (f"/{addrs[0]['uuid']}" if addrs else ""),
            {"address1": addr["line"][0], "preferred": True})
    print(f"      Registered in EHR as {mrn} (uuid {ehr_patient_uuid})")

    # --- 3. Encounter in the EHR --------------------------------------------
    _, vtypes = ehr("GET", f"{EHR_REST}/visittype")
    _, locs = ehr("GET", f"{EHR_REST}/location?tag="
                  + urllib.parse.quote("Visit Location"))
    if not vtypes["results"] or not locs["results"]:
        fail("EHR has no visit type / visit location to create an encounter with")
    _, visit = ehr("POST", f"{EHR_REST}/visit", {
        "patient": ehr_patient_uuid,
        "visitType": vtypes["results"][0]["uuid"],
        "location": locs["results"][0]["uuid"],
    })
    visit_uuid = visit["uuid"]
    print(f"[3/6] Created encounter (visit {visit_uuid}, "
          f"type {vtypes['results'][0]['display']})")

    # --- 4. Wait for Mirth to carry both across -----------------------------
    print(f"[4/6] Polling HIE (timeout {args.timeout}s) ...")
    deadline = time.time() + args.timeout
    hie_patient = hie_encounter = None
    while time.time() < deadline and not (hie_patient and hie_encounter):
        if not hie_patient:
            _, b = hie("GET", f"{HIE_FHIR}/Patient?identifier="
                       + urllib.parse.quote(f"{PATIENT_SYSTEM}|{mrn}", safe=""))
            if b.get("total", 0) == 1:
                hie_patient = b["entry"][0]["resource"]
                print(f"      patient arrived: Patient/{hie_patient['id']} "
                      f"({int(deadline - time.time())}s left)")
        if hie_patient and not hie_encounter:
            _, b = hie("GET", f"{HIE_FHIR}/Encounter?identifier="
                       + urllib.parse.quote(f"{ENCOUNTER_SYSTEM}|{visit_uuid}", safe=""))
            if b.get("total", 0) == 1:
                hie_encounter = b["entry"][0]["resource"]
                print(f"      encounter arrived: Encounter/{hie_encounter['id']}")
        if not (hie_patient and hie_encounter):
            time.sleep(10)
    if not hie_patient:
        fail(f"patient {mrn} did not appear in the HIE within {args.timeout}s")
    if not hie_encounter:
        fail(f"encounter {visit_uuid} did not appear in the HIE within {args.timeout}s")

    subject = hie_encounter.get("subject", {}).get("reference")
    if subject != f"Patient/{hie_patient['id']}":
        fail(f"encounter subject is {subject!r}, expected "
             f"Patient/{hie_patient['id']} (identifier resolution broken)")
    systems = [i.get("system") for i in hie_patient.get("identifier", [])]
    if systems != [PATIENT_SYSTEM]:
        fail(f"HIE patient identifier systems are {systems}, expected "
             f"exactly [{PATIENT_SYSTEM}] (no EHR-internal identifiers may leak)")
    print("      subject resolved by identifier; identifier systems correct")

    # --- 5. Population invariants + duplicate-person callout ----------------
    synthea_now = hie_count("Patient", SYNTHEA_SYSTEM + "|")
    participant_now = hie_count("Patient", PATIENT_SYSTEM + "|")
    if synthea_now != base_synthea:
        fail(f"Synthea population changed: {base_synthea} -> {synthea_now} "
             "(the new patient must be additive, never a collision)")
    if participant_now != base_participant + 1:
        fail(f"participant count {participant_now}, expected {base_participant + 1}")
    print(f"[5/6] Invariants hold: synthea={synthea_now} (unchanged), "
          f"participant={participant_now} (+1)")

    print(f"""
      INTENTIONAL DUPLICATE-PERSON ARTIFACT (ADR 0003 - not a bug):
      the HIE now holds two Patient resources for the same human --
        Patient/{donor['id']}  identifier {SYNTHEA_SYSTEM}|... (Synthea original)
        Patient/{hie_patient['id']}  identifier {PATIENT_SYSTEM}|{mrn} (via {EHR_FHIR.split('/')[2]})
      Record linkage across these is the staged Phase 3 MPI/dedup lesson
      (docs/phase3-parking-lot.md).""")

    # --- 6. Cleanup ----------------------------------------------------------
    if args.keep:
        print(f"[6/6] --keep: leaving {mrn} in the EHR and HIE")
    else:
        # Order matters twice over: void in the EHR first (so Mirth's polls
        # stop returning the records), encounters before patients (HAPI
        # enforces referential integrity on delete).
        ehr("DELETE", f"{EHR_FHIR}/Encounter/{visit_uuid}")
        ehr("DELETE", f"{EHR_FHIR}/Patient/{ehr_patient_uuid}")
        hie("DELETE", f"{HIE_FHIR}/Encounter/{hie_encounter['id']}")
        hie("DELETE", f"{HIE_FHIR}/Patient/{hie_patient['id']}")
        print(f"[6/6] Cleaned up: voided in EHR, deleted from HIE "
              f"(HIE back to total={hie_count('Patient')})")

    print("\nPASS: participant -> Mirth -> HIE round trip verified.")


if __name__ == "__main__":
    main()
