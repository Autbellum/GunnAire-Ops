#!/usr/bin/env python3
"""Print the processing state of the latest GunnAire Ops TestFlight builds.

Signs an App Store Connect API token (ES256) with the same key the upload
uses, via the openssl binary, because PyJWT is not installed on this Mac.
Run with the Bash sandbox allowing api.appstoreconnect.apple.com.

    python3 asc-builds.py            # six newest builds
    python3 asc-builds.py 12         # twelve newest builds
"""
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request

KEY_ID = "7YBP3GY874"
ISSUER = "08292696-bd8c-4732-9976-2ad43c1a39aa"
BUNDLE_ID = "com.gunnaire.businesssuite"
KEY_PATH = os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8")


def b64(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def der_to_raw_signature(der: bytes) -> bytes:
    """ES256 JWTs carry r||s (64 bytes); openssl emits DER."""
    assert der[0] == 0x30, "not a DER sequence"
    index = 2
    parts = []
    for _ in range(2):
        assert der[index] == 0x02, "expected DER integer"
        length = der[index + 1]
        value = der[index + 2:index + 2 + length].lstrip(b"\x00")
        parts.append(value.rjust(32, b"\x00"))
        index += 2 + length
    return b"".join(parts)


def token() -> str:
    now = int(time.time())
    header = b64(json.dumps({"alg": "ES256", "kid": KEY_ID, "typ": "JWT"}).encode())
    payload = b64(json.dumps({"iss": ISSUER, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}).encode())
    signing_input = f"{header}.{payload}".encode()
    with tempfile.NamedTemporaryFile(delete=False) as handle:
        handle.write(signing_input)
        path = handle.name
    try:
        der = subprocess.check_output(["openssl", "dgst", "-sha256", "-sign", KEY_PATH, path])
    finally:
        os.unlink(path)
    return f"{header}.{payload}.{b64(der_to_raw_signature(der))}"


def get(path: str, bearer: str) -> dict:
    request = urllib.request.Request(
        "https://api.appstoreconnect.apple.com" + path,
        headers={"Authorization": "Bearer " + bearer},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def main() -> None:
    limit = int(sys.argv[1]) if len(sys.argv) > 1 else 6
    bearer = token()
    apps = get(f"/v1/apps?filter[bundleId]={BUNDLE_ID}", bearer)
    app_id = apps["data"][0]["id"]
    builds = get(
        f"/v1/builds?filter[app]={app_id}&sort=-uploadedDate&limit={limit}"
        "&fields[builds]=version,uploadedDate,processingState,expired",
        bearer,
    )
    for build in builds["data"]:
        attributes = build["attributes"]
        print(
            attributes["version"],
            attributes["processingState"],
            attributes["uploadedDate"],
            "expired" if attributes["expired"] else "",
        )


if __name__ == "__main__":
    main()
