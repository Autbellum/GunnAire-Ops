"""Capture isolated author-only HTTP pages for native contract verification."""
import contextlib
import json
import sys

from Backend.test_staff_workspace_field_updates import StaffFieldUpdatesHTTPTests


def capture():
    result = {}
    for outcome in ("kept", "applied"):
        fixture = StaffFieldUpdatesHTTPTests()
        fixture.setUp()
        try:
            def retain(name, response):
                status, body = response
                assert status == 200, (status, body)
                result[name] = body
            retain(outcome + "Waiting", fixture.read(fixture.f.id))
            if outcome == "kept":
                fixture.keep()
            else:
                claim = fixture.f.prepare_body()
                assert fixture.f.post("prepare", claim)[0] == 200
                fixture.f.advance_job(fixture.f.command["value"]["text"]["_0"])
                assert fixture.f.post("confirm", fixture.f.confirm_body(claim))[0] == 200
            retain(outcome, fixture.read(fixture.f.id))
            retain(outcome + "Empty", fixture.read(after=fixture.f.id))
        finally:
            fixture.doCleanups()
    return result


if __name__ == "__main__":
    with contextlib.redirect_stdout(sys.stderr):
        result = capture()
    print(json.dumps(result, sort_keys=True, ensure_ascii=True, indent=2))
