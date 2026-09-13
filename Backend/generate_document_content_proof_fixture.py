"""Capture only isolated test-server upload and staff-media wire contracts."""
import base64
import contextlib
import json
import sys

from Backend import test_document_content_proof as http_tests


def capture():
    fixture = http_tests.DocumentContentProofHTTPTests()
    fixture.setUp()
    try:
        status, upload = fixture.upload()
        assert status == 201, (status, upload)
        status, proof = fixture.manifest(upload["id"])
        assert status == 200, (status, proof)
        fixture.f.seed_with_media()
        status, grant = fixture.f.media()
        assert status == 200, (status, grant)
        return dict(proof=proof, dataBase64=base64.b64encode(b"original-file").decode("ascii"),
                    staffGrant=grant, staffDataBase64=base64.b64encode(fixture.f.payload_bytes).decode("ascii"))
    finally:
        fixture.doCleanups()


if __name__ == "__main__":
    with contextlib.redirect_stdout(sys.stderr):
        result = capture()
    print(json.dumps(result, sort_keys=True, indent=2))
