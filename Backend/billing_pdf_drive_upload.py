"""Bounded Google Drive creation for a retained, exact billing PDF revision.

The caller must persist the generated Drive ID in the reservation before
calling create. A lost response can then be reconciled against that ID.
"""

from __future__ import annotations

import hashlib
import http.client
import json
import re
import secrets
import urllib.error
import urllib.parse
import urllib.request

try:
    from . import google_connections
except ImportError:
    import google_connections


_FILE_ID = re.compile(r"[A-Za-z0-9_-]{1,200}\Z")
_HEX = re.compile(r"[0-9a-f]{64}\Z")
_GENERATE = "https://www.googleapis.com/drive/v3/files/generateIds?count=1&space=drive&type=files"
_CREATE = "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id"
_MAX_PDF = 25 * 1024 * 1024


class ProviderUploadError(RuntimeError):
    pass


def transport(request: urllib.request.Request, *, maximum: int = 16_384) -> tuple[int, dict | None]:
    """Send only the two fixed Drive endpoints, without redirects or retries."""
    parsed = urllib.parse.urlsplit(request.full_url)
    if (parsed.scheme != "https" or parsed.hostname != "www.googleapis.com" or
            parsed.port not in (None, 443) or parsed.username is not None or
            parsed.password is not None or parsed.fragment or
            request.full_url not in (_GENERATE, _CREATE) or
            (request.full_url == _GENERATE and (request.get_method() != "GET" or request.data is not None)) or
            (request.full_url == _CREATE and (request.get_method() != "POST" or request.data is None)) or
            maximum != 16_384):
        raise ProviderUploadError("Invalid Drive upload target")
    try:
        with urllib.request.build_opener(google_connections.NoRedirect).open(request, timeout=30) as response:
            status = response.status
            raw = response.read(maximum + 1)
        if len(raw) > maximum or status not in (200, 201):
            raise ProviderUploadError("Drive did not confirm the file operation")
        value = google_connections.strict_json(raw.decode("utf-8"))
        if not isinstance(value, dict):
            raise ProviderUploadError("Drive returned invalid file metadata")
        return status, value
    except urllib.error.HTTPError as error:
        status = error.code
        error.close()
        if request.full_url == _CREATE and status == 409:
            return 409, None
        raise ProviderUploadError("Drive file operation was not confirmed") from None
    except (urllib.error.URLError, TimeoutError, UnicodeError, ValueError,
            json.JSONDecodeError, http.client.IncompleteRead, OSError) as error:
        raise ProviderUploadError("Drive file operation was not confirmed") from error


class BillingPDFDriveUpload:
    def __init__(self, send=transport):
        self.send = send

    def generate_id(self, access_token: str) -> str:
        token = self._token(access_token)
        request = urllib.request.Request(_GENERATE, headers={
            "Authorization": "Bearer " + token, "Accept": "application/json"}, method="GET")
        status, value = self.send(request)
        ids = value.get("ids") if isinstance(value, dict) else None
        if (status != 200 or not isinstance(ids, list) or len(ids) != 1 or
                not isinstance(ids[0], str) or _FILE_ID.fullmatch(ids[0]) is None or
                value.get("space") != "drive"):
            raise ProviderUploadError("Drive did not reserve one usable file ID")
        return ids[0]

    def create(self, key, reservation, data: bytes, access_token: str) -> str:
        token = self._token(access_token)
        file_id = reservation.drive_file_id
        digest = reservation.content_digest
        if (not isinstance(file_id, str) or _FILE_ID.fullmatch(file_id) is None or
                not isinstance(digest, str) or _HEX.fullmatch(digest) is None or
                not reservation.artifact_ready or type(data) is not bytes or
                not 5 <= len(data) <= _MAX_PDF or not data.startswith(b"%PDF-") or
                reservation.artifact_bytes != len(data) or
                hashlib.sha256(data).hexdigest() != digest or key != reservation.key):
            raise ProviderUploadError("Reserved Drive PDF differs from retained bytes")
        metadata = {
            "id": file_id,
            "name": f"GunnAire-{key.document_kind.title()}-{key.document_id}.pdf",
            "mimeType": "application/pdf",
            "appProperties": {
                "gunnaireSchema": "2",
                "gunnaireAttachmentID": reservation.attachment_id,
                "gunnaireCompanyID": key.company_id,
                "gunnaireDocumentKind": key.document_kind,
                "gunnaireDocumentID": key.document_id,
                "gunnaireSourceDigest": key.source_digest,
                "gunnaireRendererVersion": key.renderer_version,
                "gunnaireContentSHA256": digest,
            },
        }
        boundary = "gunnaire-" + secrets.token_hex(24)
        body = (b"--" + boundary.encode() + b"\r\n"
                b"Content-Type: application/json; charset=UTF-8\r\n\r\n" +
                json.dumps(metadata, sort_keys=True, separators=(",", ":")).encode("utf-8") +
                b"\r\n--" + boundary.encode() + b"\r\n"
                b"Content-Type: application/pdf\r\n\r\n" + data +
                b"\r\n--" + boundary.encode() + b"--\r\n")
        request = urllib.request.Request(_CREATE, data=body, headers={
            "Authorization": "Bearer " + token,
            "Content-Type": "multipart/related; boundary=" + boundary,
            "Accept": "application/json"}, method="POST")
        status, value = self.send(request)
        if status == 409:
            return file_id
        if status not in (200, 201) or not isinstance(value, dict) or value.get("id") != file_id:
            raise ProviderUploadError("Drive returned a different file ID")
        return file_id

    @staticmethod
    def _token(value: str) -> str:
        if (not isinstance(value, str) or not 1 <= len(value) <= 4096 or
                any(ord(character) <= 32 or ord(character) >= 127 for character in value)):
            raise ProviderUploadError("Google access is unavailable")
        return value
