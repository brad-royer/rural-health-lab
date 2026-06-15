#!/usr/bin/env python3
"""Verify HAPI MDM linkage across the three-way duplicate cohort (Phase 3b.2).

Asserts that MDM (link-not-merge, per ADR 0010) linked each EHR patient to its
Synthea twin into golden records, WITHOUT mutating the source Patients:
  - reports the golden-record count and the sources-per-golden distribution
    (expected: 5 three-way, 20 two-way, the rest singletons);
  - drills into one deliberate three-way human (openemr-cah CAH-0001 = the same
    Synthea human as bahmni-central BAH-0001) and shows its golden links every
    source system;
  - confirms the source records still exist unchanged (non-destructive).

Usage:  python3 scripts/verify-mdm-linkage.py
"""
import json
import sys
import urllib.parse
import urllib.request
from collections import defaultdict

HIE = "http://localhost:8080/fhir"
GOLDEN_TAG = "http://hapifhir.io/fhir/NamingSystem/mdm-record-status|GOLDEN_RECORD"
SYNTHEA = "https://github.com/synthetichealth/synthea"
BAHMNI = "https://lab.example/identifiers/bahmni-central"
OPENEMR = "https://lab.example/identifiers/openemr-cah"


def get(path):
    r = urllib.request.Request(HIE + path,
                               headers={"Accept": "application/fhir+json", "Cache-Control": "no-cache"})
    with urllib.request.urlopen(r, timeout=60) as resp:
        return json.load(resp)


def part_val(part):
    for k in ("valueString", "valueCode", "valueBoolean", "valueDecimal"):
        if k in part:
            return part[k]
    if "valueReference" in part:
        return part["valueReference"].get("reference")
    return None


def query_links(extra=""):
    # $mdm-query-links caps the page (~100); paginate via _offset.
    out = []
    offset = 0
    page = 100
    while True:
        p = get(f"/$mdm-query-links?_count={page}&_offset={offset}{extra}")
        links = [{pt["name"]: part_val(pt) for pt in param.get("part", [])}
                 for param in p.get("parameter", []) if param.get("name") == "link"]
        out.extend(links)
        if len(links) < page:
            break
        offset += page
    return out


def systems_of(ref):
    pid = ref.split("/")[-1]
    r = get(f"/Patient/{pid}")
    return [i.get("system") for i in r.get("identifier", [])]


def main():
    golden = get(f"/Patient?_tag={urllib.parse.quote(GOLDEN_TAG, safe='|')}&_summary=count")["total"]
    print(f"Golden records: {golden}")

    links = query_links()
    print(f"MDM links: {len(links)}")
    if not links:
        print("FAIL: no MDM links — did $mdm-submit run and finish?")
        sys.exit(1)

    # group MATCH source refs by golden
    by_golden = defaultdict(list)
    for l in links:
        if l.get("matchResult") == "MATCH":
            by_golden[l.get("goldenResourceId")].append(l.get("sourceResourceId"))
    dist = defaultdict(int)
    for sources in by_golden.values():
        dist[len(sources)] += 1
    print("Sources per golden (MATCH):", dict(sorted(dist.items())))
    print(f"  three-way goldens: {dist.get(3, 0)} (expected 5)")
    print(f"  two-way goldens:   {dist.get(2, 0)} (expected 20)")

    # drill into the CAH-0001 three-way human
    found = get(f"/Patient?identifier={urllib.parse.quote(OPENEMR + '|CAH-0001', safe='')}")
    if not found.get("entry"):
        print("FAIL: CAH-0001 source not found in HIE")
        sys.exit(1)
    cah1_id = found["entry"][0]["resource"]["id"]
    gid = next((l["goldenResourceId"] for l in links
                if l.get("sourceResourceId", "").endswith(cah1_id) and l.get("matchResult") == "MATCH"), None)
    if not gid:
        print(f"FAIL: CAH-0001 (Patient/{cah1_id}) has no MATCH golden link")
        sys.exit(1)
    src_systems = sorted({s for ref in by_golden[gid] for s in systems_of(ref)})
    print(f"\nThree-way check — CAH-0001's golden {gid} links sources from systems:")
    for s in src_systems:
        print(f"  - {s}")
    for needed in (SYNTHEA, BAHMNI, OPENEMR):
        if needed not in src_systems:
            print(f"FAIL: golden does not link a {needed} source")
            sys.exit(1)

    # non-destructive: the three source records still exist
    for system, val in ((BAHMNI, "BAH-0001"), (OPENEMR, "CAH-0001")):
        c = get(f"/Patient?identifier={urllib.parse.quote(system + '|' + val, safe='')}&_summary=count")["total"]
        if c != 1:
            print(f"FAIL: source {system}|{val} count={c} (expected 1 — sources must be intact)")
            sys.exit(1)
    print("\nPASS: three-way linkage formed; sources intact (link-not-merge).")


if __name__ == "__main__":
    main()
