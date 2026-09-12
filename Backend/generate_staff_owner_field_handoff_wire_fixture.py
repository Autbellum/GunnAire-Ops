"""Actual isolated HTTP handoff, not a Swift-to-Swift protocol round trip."""
import contextlib
import json
import sys
import uuid

from Backend.test_staff_owner_field_handoffs import OwnerFieldHandoffHTTPTests


def capture():
    fixture = OwnerFieldHandoffHTTPTests()
    try:
        fixture.setUp()
        claimed = fixture.f.get(fixture.f.id)[1]
        status, receipt = fixture.release()
        assert status == 200, (status, receipt)
        released = fixture.f.get(fixture.f.id)[1]
        next_request = dict(fixture.prepare, operationID=str(uuid.uuid4()), ownerStoreID=str(uuid.uuid4()))
        status, next_claim = fixture.f.post("prepare", next_request)
        assert status == 200, (status, next_claim)
        return dict(claimed=claimed, prepare=fixture.prepare, request=fixture.body, receipt=receipt,
                    released=released, nextClaim=next_claim)
    finally:
        fixture.doCleanups()


if __name__ == "__main__":
    with contextlib.redirect_stdout(sys.stderr): result = capture()
    print(json.dumps(result, sort_keys=True, ensure_ascii=True, indent=2))
