"""Isolated real HTTP contract; no live accounts or production credentials."""
import contextlib
import json
import sys

from Backend.test_staff_owner_field_observations import OwnerFieldObservationHTTPTests


def capture():
    fixture = OwnerFieldObservationHTTPTests()
    fixture.setUp()
    try:
        request = fixture.publish()
        original = fixture.f.get(fixture.f.id)[1]
        status, receipt = fixture.post(request)
        assert status == 200, (status, receipt)
        return dict(claimed=original, request=request, observation=receipt,
                    completed=fixture.f.get(fixture.f.id)[1])
    finally:
        fixture.doCleanups()


if __name__ == "__main__":
    with contextlib.redirect_stdout(sys.stderr):
        result = capture()
    print(json.dumps(result, ensure_ascii=True, sort_keys=True, indent=2))
