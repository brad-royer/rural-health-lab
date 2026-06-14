#!/usr/bin/env python3
"""Verify a participant EHR -> Mirth -> HIE onboarding round trip.

The Phase 2 closeout validation, generalized in Phase 3a.6 into the Phase 3
acceptance-test template: one EHR-agnostic flow, with the EHR-specific
operations (register patient, create encounter, clean up) behind a pluggable
backend (scripts/ehr_backends.py) selected by --ehr. Proven against Bahmni
(Phase 2) and OpenEMR (Phase 3a).

The flow:
  1. Record HIE baselines (total / Synthea-population / participant counts).
  2. Pick a deterministic Synthea "donor" from the HIE and register the *same
     human* in the participant EHR under a fresh MRN (VRFY-<UTC>) - per ADR
     0003/0008, demographics overlap, identifiers disjoint.
  3. Create an encounter for that patient in the EHR.
  4. Poll the HIE until both arrive via the participant's Mirth, asserting the
     participant identifier systems and that the encounter subject resolved to
     the HIE patient by identifier.
  5. Assert the Synthea population is UNCHANGED (additive, no collision) and
     call out the resulting duplicate-person condition as the intentional
     ADR 0003/0008 artifact - not a bug.
  6. Clean up (EHR + HIE) unless --keep.

Usage:  python3 scripts/verify-onboarding.py --ehr {bahmni|openemr} [--keep] [--timeout N]
"""
import argparse
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from ehr_backends import BACKENDS

HIE_FHIR = os.environ.get("HIE_FHIR_BASE", "http://localhost:8080/fhir")
SYNTHEA_SYSTEM = os.environ.get("SYNTHEA_SYSTEM", "https://github.com/synthetichealth/synthea")

# Participant identifier systems default per EHR; override via env.
DEFAULTS = {
    "bahmni": ("https://lab.example/identifiers/bahmni-central",
               "https://lab.example/identifiers/bahmni-central/encounter"),
    "openemr": ("https://lab.example/identifiers/openemr-cah",
                "https://lab.example/identifiers/openemr-cah/encounter"),
}

_CTX = ssl.create_default_context()
_CTX.check_hostname = False
_CTX.verify_mode = ssl.CERT_NONE


def fail(msg):
    print(f"\nFAIL: {msg}")
    sys.exit(1)


def hie(method, url):
    # HAPI reuses identical search results ~60s; bypass so consecutive runs
    # read fresh counts (2.5 lesson).
    r = urllib.request.Request(url, method=method,
                               headers={"Accept": "application/fhir+json", "Cache-Control": "no-cache"})
    with urllib.request.urlopen(r, context=_CTX, timeout=30) as resp:
        raw = resp.read()
        return resp.status, (json.loads(raw) if raw.strip() else {})


def hie_count(resource, ident_prefix=None):
    q = f"{HIE_FHIR}/{resource}?_summary=count"
    if ident_prefix:
        q += "&identifier=" + urllib.parse.quote(ident_prefix, safe="")
    _, b = hie("GET", q)
    return b.get("total", 0)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--ehr", choices=list(BACKENDS), default="bahmni")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--timeout", type=int, default=int(os.environ.get("TIMEOUT_SECONDS", 300)))
    args = ap.parse_args()

    patient_system = os.environ.get("PATIENT_SYSTEM", DEFAULTS[args.ehr][0])
    encounter_system = os.environ.get("ENCOUNTER_SYSTEM", DEFAULTS[args.ehr][1])
    backend = BACKENDS[args.ehr]()
    mrn = "VRFY-" + time.strftime("%Y%m%d%H%M%S", time.gmtime())
    print(f"EHR={backend.name}  verification MRN={mrn}\n")

    # 1. Baselines -----------------------------------------------------------
    base_total = hie_count("Patient")
    base_synthea = hie_count("Patient", SYNTHEA_SYSTEM + "|")
    base_participant = hie_count("Patient", patient_system + "|")
    print(f"[1/6] HIE baselines: total={base_total}, synthea={base_synthea}, "
          f"participant={base_participant}")

    # 2. Donor + EHR registration -------------------------------------------
    _, donors = hie("GET", f"{HIE_FHIR}/Patient?identifier="
                    + urllib.parse.quote(SYNTHEA_SYSTEM + "|", safe="") + "&_sort=family&_count=1")
    if not donors.get("entry"):
        fail("no Synthea-population patient in the HIE to act as donor")
    donor = donors["entry"][0]["resource"]
    name = next(n for n in donor["name"] if n.get("use", "official") == "official")
    print(f"[2/6] Donor (same human): {' '.join(name.get('given', []))} {name.get('family')} "
          f"b. {donor.get('birthDate')} (HIE Patient/{donor['id']})")
    handle = backend.register_patient(donor, mrn)
    print(f"      Registered in {backend.name} as {mrn}")

    # 3. Encounter -----------------------------------------------------------
    enc_value = backend.create_encounter(handle)
    print(f"[3/6] Created encounter ({enc_value})")

    # 4. Wait for both to arrive via Mirth -----------------------------------
    print(f"[4/6] Polling HIE (timeout {args.timeout}s) ...")
    deadline = time.time() + args.timeout
    hp = he = None
    while time.time() < deadline and not (hp and he):
        if not hp:
            _, b = hie("GET", f"{HIE_FHIR}/Patient?identifier="
                       + urllib.parse.quote(f"{patient_system}|{mrn}", safe=""))
            if b.get("total", 0) == 1:
                hp = b["entry"][0]["resource"]
                print(f"      patient arrived: Patient/{hp['id']} ({int(deadline - time.time())}s left)")
        if hp and not he:
            _, b = hie("GET", f"{HIE_FHIR}/Encounter?identifier="
                       + urllib.parse.quote(f"{encounter_system}|{enc_value}", safe=""))
            if b.get("total", 0) == 1:
                he = b["entry"][0]["resource"]
                print(f"      encounter arrived: Encounter/{he['id']}")
        if not (hp and he):
            time.sleep(10)
    if not hp:
        fail(f"patient {mrn} did not appear in the HIE within {args.timeout}s")
    if not he:
        fail(f"encounter {enc_value} did not appear in the HIE within {args.timeout}s")

    subject = he.get("subject", {}).get("reference")
    if subject != f"Patient/{hp['id']}":
        fail(f"encounter subject {subject!r}, expected Patient/{hp['id']} (identifier resolution broken)")
    systems = [i.get("system") for i in hp.get("identifier", [])]
    if systems != [patient_system]:
        fail(f"HIE patient identifier systems {systems}, expected exactly [{patient_system}]")
    print("      subject resolved by identifier; identifier systems correct")

    # 5. Invariants + duplicate callout -------------------------------------
    synthea_now = hie_count("Patient", SYNTHEA_SYSTEM + "|")
    participant_now = hie_count("Patient", patient_system + "|")
    if synthea_now != base_synthea:
        fail(f"Synthea population changed: {base_synthea} -> {synthea_now} (must be additive)")
    if participant_now != base_participant + 1:
        fail(f"participant count {participant_now}, expected {base_participant + 1}")
    print(f"[5/6] Invariants hold: synthea={synthea_now} (unchanged), participant={participant_now} (+1)")
    print(f"""
      INTENTIONAL DUPLICATE-PERSON ARTIFACT (ADR 0003/0008 - not a bug):
      the same human now exists in the HIE as the Synthea original
      (Patient/{donor['id']}) and as {patient_system}|{mrn}
      (Patient/{hp['id']}), under disjoint identifier systems. Record linkage
      is the Phase 3b MPI lesson (docs/phase3-parking-lot.md).""")

    # 6. Cleanup -------------------------------------------------------------
    if args.keep:
        print(f"[6/6] --keep: leaving {mrn} in the {backend.name} EHR and HIE")
    else:
        backend.delete(handle, enc_value)
        hie("DELETE", f"{HIE_FHIR}/Encounter/{he['id']}")
        hie("DELETE", f"{HIE_FHIR}/Patient/{hp['id']}")
        print(f"[6/6] Cleaned up EHR + HIE (HIE back to total={hie_count('Patient')})")

    print(f"\nPASS: {backend.name} -> Mirth -> HIE round trip verified.")


if __name__ == "__main__":
    main()
