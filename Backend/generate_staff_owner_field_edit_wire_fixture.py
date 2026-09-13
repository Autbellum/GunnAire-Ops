"""Capture actual isolated HTTP responses for native wire-contract tests.

Run as a module; emits fixture JSON to stdout, fixture-server logs to stderr.
Never uses production configuration or credentials.
"""
import contextlib
import json
import sys
import uuid

from Backend.test_staff_owner_field_edits import OwnerFieldEditHTTPTests
from Backend import staff_owner_field_resolutions as resolutions


def capture():
    fixture = OwnerFieldEditHTTPTests()
    fixture.setUp()
    try:
        results = {}
        def retain(name, result):
            status, payload = result
            assert status == 200, (name, status, payload)
            results[name] = payload
        retain("page", fixture.get())
        retain("original", fixture.get(fixture.id))
        body = fixture.prepare_body()
        retain("prepared", fixture.post("prepare", body))
        retain("claimed", fixture.get(fixture.id))
        second = fixture.f.command_body()
        assert fixture.f.submit(body=second)[0] == 200
        original_id = fixture.id
        fixture.id = second["commandID"]
        second_entry = fixture.get(fixture.id)[1]
        keep = dict(**fixture.f.scope, schema=resolutions.SCHEMA, commandID=fixture.id,
            operationID=str(uuid.uuid4()), ownerStoreID=fixture.owner_store, claimOperationID="",
            expectedRevision=second_entry["current"]["revision"], expectedValue=second_entry["current"]["value"])
        retain("kept", fixture.post("keep-office", keep))
        retain("retained", fixture.get(fixture.id))
        fixture.id = original_id
        fixture.advance_job(fixture.command["value"]["text"]["_0"])
        retain("published", fixture.post("confirm", fixture.confirm_body(body)))
        retain("completed", fixture.get(fixture.id))
        retain("emptyPage", fixture.get())
        return results
    finally:
        fixture.doCleanups()


if __name__ == "__main__":
    with contextlib.redirect_stdout(sys.stderr):
        responses = capture()
    print(json.dumps(responses, ensure_ascii=True, sort_keys=True, indent=2))
