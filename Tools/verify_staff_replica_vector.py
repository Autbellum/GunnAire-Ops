"""Validate an actual native XCTest JSON attachment against the server contract.

Print only coverage/counts, never the synthetic record body or customer fields.
This is serialization evidence, not signed CloudKit delivery or full-suite proof.
"""
import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from Backend import staff_replica_contract as contract, cloudkit_staff_shares as sharing


def verify(value):
    if (not isinstance(value, dict) or set(value) != {"schema", "coverage", "records"}
            or value["schema"] != contract.SCHEMA_VERSION or value["coverage"] != contract.COVERAGE
            or not isinstance(value["records"], list) or len(value["records"]) != len(contract.COVERAGE)):
        raise ValueError("The native vector must exercise the exact supported schema")
    kinds = []
    for record in value["records"]:
        if not isinstance(record, dict) or set(record) != {"kind", "id", "fields"}:
            raise ValueError("Invalid native record envelope")
        sharing.identifier(record["id"])
        contract.validate(record["kind"], record["fields"])
        kinds.append(record["kind"])
    if sorted(kinds) != contract.COVERAGE:
        raise ValueError("Native vector skipped or repeated a supported kind")
    return {"schema": contract.SCHEMA_VERSION, "validatedKinds": kinds, "recordCount": len(kinds)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("attachment", type=Path)
    args = parser.parse_args()
    try:
        if args.attachment.stat().st_size > 512 * 1024:
            raise ValueError("Native vector exceeds its bounded size")
        result = verify(json.loads(args.attachment.read_text()))
    except (OSError, ValueError, TypeError, sharing.AttemptError):
        parser.exit(1, "Native staff replica contract verification failed\n")
    print(json.dumps(result, sort_keys=True))
