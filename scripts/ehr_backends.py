#!/usr/bin/env python3
"""Per-participant EHR backends for verify-onboarding.py (Phase 3a.6).

The generic verification flow (donor selection, HIE polling, invariants,
duplicate callout) is EHR-agnostic. The EHR-specific operations - register a
patient, create an encounter, clean up - are the "seam" that differs per
participant. Each backend implements:

    register_patient(donor, mrn) -> handle      # same human, new MRN
    create_encounter(handle)     -> enc_value   # value of the HIE encounter id
    delete(handle, enc_value)                   # cleanup in the EHR

`enc_value` / `mrn` are the *values* the HIE-side identifiers will carry (the
systems come from the caller's PATIENT_SYSTEM / ENCOUNTER_SYSTEM env).

Backends:
  - bahmni: OpenMRS FHIR2 + REST over basic auth (Phase 2 worked example).
  - openemr: FHIR R4 over SMART Backend Services OAuth, with DB seams for the
    bits OpenEMR's API won't do under machine auth (pubpid, encounter create) -
    see docs/runbooks/phase3a-verification.md.
"""
import base64
import json
import os
import ssl
import subprocess
import urllib.parse
import urllib.request
import uuid as uuidlib

_CTX = ssl.create_default_context()
_CTX.check_hostname = False
_CTX.verify_mode = ssl.CERT_NONE


def _req(method, url, headers, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method=method, headers=headers)
    with urllib.request.urlopen(r, context=_CTX, timeout=30) as resp:
        raw = resp.read()
        return resp.status, (json.loads(raw) if raw.strip() else {}), dict(resp.headers)


# --------------------------------------------------------------------------- #
class BahmniBackend:
    name = "bahmni"

    def __init__(self):
        self.fhir = os.environ.get("EHR_FHIR_BASE", "https://192.168.1.230/openmrs/ws/fhir2/R4")
        self.rest = os.environ.get("EHR_REST_BASE", "https://192.168.1.230/openmrs/ws/rest/v1")
        user = os.environ.get("EHR_USER", "superman")
        pw = os.environ.get("EHR_PASSWORD", "Admin123")
        self.id_type = os.environ.get("EHR_IDENTIFIER_TYPE", "Patient Identifier")
        self.auth = "Basic " + base64.b64encode(f"{user}:{pw}".encode()).decode()

    def _h(self, body=False):
        h = {"Authorization": self.auth, "Accept": "application/fhir+json, application/json"}
        if body:
            h["Content-Type"] = "application/fhir+json"
        return h

    def register_patient(self, donor, mrn):
        _, types, _ = _req("GET", f"{self.rest}/patientidentifiertype?v=custom:(uuid,name)", self._h())
        type_uuid = next(t["uuid"] for t in types["results"] if t["name"] == self.id_type)
        name = next(n for n in donor["name"] if n.get("use", "official") == "official")
        addr = (donor.get("address") or [{}])[0]
        _, created, _ = _req("POST", f"{self.fhir}/Patient", self._h(True), {
            "resourceType": "Patient",
            "identifier": [{"use": "official",
                            "type": {"coding": [{"code": type_uuid}], "text": self.id_type},
                            "value": mrn}],
            "name": [{"use": "official", "family": name.get("family"), "given": name.get("given", [])}],
            "gender": donor.get("gender"), "birthDate": donor.get("birthDate"),
            "address": [{k: addr[k] for k in ("line", "city", "state", "postalCode", "country") if k in addr}],
        })
        puuid = created["id"]
        if addr.get("line"):
            _, pdata, _ = _req("GET", f"{self.rest}/patient/{puuid}?v=custom:(person:(addresses:(uuid)))", self._h())
            addrs = pdata["person"]["addresses"]
            _req("POST", f"{self.rest}/person/{puuid}/address" + (f"/{addrs[0]['uuid']}" if addrs else ""),
                 self._h(True), {"address1": addr["line"][0], "preferred": True})
        return {"puuid": puuid}

    def create_encounter(self, handle):
        _, vt, _ = _req("GET", f"{self.rest}/visittype", self._h())
        _, locs, _ = _req("GET", f"{self.rest}/location?tag=" + urllib.parse.quote("Visit Location"), self._h())
        _, visit, _ = _req("POST", f"{self.rest}/visit", self._h(True),
                           {"patient": handle["puuid"], "visitType": vt["results"][0]["uuid"],
                            "location": locs["results"][0]["uuid"]})
        return visit["uuid"]

    def delete(self, handle, enc_value):
        if enc_value:
            _req("DELETE", f"{self.fhir}/Encounter/{enc_value}", self._h())
        _req("DELETE", f"{self.fhir}/Patient/{handle['puuid']}", self._h())


# --------------------------------------------------------------------------- #
class OpenEMRBackend:
    name = "openemr"

    def __init__(self):
        import openemr_oauth as oauth
        self.oauth = oauth
        self.base = os.environ.get("OPENEMR_BASE", "https://192.168.1.189")
        self.fhir = f"{self.base}/apis/default/fhir"
        self.ssh_key = os.environ.get("EHR_SSH_KEY", os.path.join(
            os.path.dirname(__file__), "..", "infra", "hyperv", "cloud-init",
            ".generated", "rhl-acquired-cah", "id_ed25519_rhl-acquired-cah"))
        self.host = os.environ.get("EHR_HOST", "ubuntu@192.168.1.189")
        self.db = os.environ.get("EHR_DB_CONTAINER", "openemr-mysql-1")
        self.token = self.oauth.get_token()

    def _h(self, body=False):
        h = {"Authorization": f"Bearer {self.token}", "Accept": "application/fhir+json"}
        if body:
            h["Content-Type"] = "application/fhir+json"
        return h

    def _sql(self, sql):
        cmd = ["ssh", "-i", self.ssh_key, "-o", "StrictHostKeyChecking=accept-new", self.host,
               f"docker exec -i {self.db} mariadb -uroot -proot -N openemr"]
        return subprocess.run(cmd, input=sql.encode(), capture_output=True, check=True).stdout.decode().strip()

    def register_patient(self, donor, mrn):
        # OpenEMR FHIR create ignores supplied identifiers; set pubpid via DB.
        name = next(n for n in donor["name"] if n.get("use", "official") == "official")
        addr = (donor.get("address") or [{}])[0]
        _, body, _ = _req("POST", f"{self.fhir}/Patient", self._h(True), {
            "resourceType": "Patient",
            "name": [{"use": "official", "family": name.get("family"), "given": name.get("given", [])}],
            "gender": donor.get("gender"), "birthDate": donor.get("birthDate"),
            "address": [{k: addr[k] for k in ("line", "city", "state", "postalCode", "country") if k in addr}],
        })
        puuid = body["uuid"]
        self._sql(f"UPDATE patient_data SET pubpid='{mrn}' WHERE uuid=UNHEX('{puuid.replace('-', '')}');")
        return {"puuid": puuid, "mrn": mrn}

    def create_encounter(self, handle):
        # OpenEMR FHIR Encounter is read-only and its standard API rejects
        # machine auth (403); create the encounter via DB (form_encounter +
        # forms), which the FHIR Encounter read then surfaces.
        out = self._sql(
            "SET @pid=(SELECT pid FROM patient_data WHERE uuid=UNHEX('" + handle["puuid"].replace("-", "") + "'));"
            "SET @enc=(SELECT COALESCE(MAX(encounter),0)+1 FROM form_encounter);"
            "SET @u=UNHEX(REPLACE(UUID(),'-',''));"
            "INSERT INTO form_encounter (uuid,date,reason,facility,facility_id,pid,encounter,provider_id,class_code)"
            " VALUES (@u,NOW(),'verify-onboarding','Your Clinic Name Here',3,@pid,@enc,1,'AMB');"
            "INSERT INTO forms (date,encounter,form_name,form_id,pid,user,groupname,authorized,deleted,formdir,provider_id)"
            " VALUES (NOW(),@enc,'New Patient Encounter',LAST_INSERT_ID(),@pid,'admin','Default',1,0,'newpatient',1);"
            "SELECT LOWER(CONCAT_WS('-',SUBSTR(HEX(@u),1,8),SUBSTR(HEX(@u),9,4),SUBSTR(HEX(@u),13,4),SUBSTR(HEX(@u),17,4),SUBSTR(HEX(@u),21)));")
        return out.splitlines()[-1].strip()

    def delete(self, handle, enc_value):
        if enc_value:
            h = enc_value.replace("-", "")
            self._sql(
                f"DELETE f FROM forms f JOIN form_encounter e ON f.encounter=e.encounter "
                f"WHERE e.uuid=UNHEX('{h}'); DELETE FROM form_encounter WHERE uuid=UNHEX('{h}');")
        self._sql(f"DELETE FROM patient_data WHERE uuid=UNHEX('{handle['puuid'].replace('-', '')}');")


BACKENDS = {"bahmni": BahmniBackend, "openemr": OpenEMRBackend}
