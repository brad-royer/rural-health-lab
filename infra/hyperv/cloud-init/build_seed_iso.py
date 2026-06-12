#!/usr/bin/env python3
"""Build a cloud-init NoCloud seed ISO (volume label CIDATA) from a
user-data and meta-data file. Used by build-seed-iso.sh — see
docs/runbooks/phase2-vm-baseline.md.
"""
import sys

import pycdlib


def main(user_data_path: str, meta_data_path: str, out_path: str) -> None:
    iso = pycdlib.PyCdlib()
    iso.new(interchange_level=3, joliet=3, rock_ridge="1.09", vol_ident="CIDATA")
    iso.add_file(user_data_path, "/USERDATA.;1", joliet_path="/user-data", rr_name="user-data")
    iso.add_file(meta_data_path, "/METADATA.;1", joliet_path="/meta-data", rr_name="meta-data")
    iso.write(out_path)
    iso.close()


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3])
