"""Read-only Google Drive proof for an exact reserved billing PDF.

The provider request is fixed-origin and bounded. It never creates, updates,
searches for, or deletes a Drive file; an uncertain read cannot confirm one.
"""

from __future__ import annotations

import hashlib
import http.client
import json
import re
import urllib.error
import urllib.parse
import urllib.request

try:
    from . import google_connections
except ImportError:
    import google_connections


_ID = re.compile(r"[A-Za-z0-9_-]{1,200}\Z")
_ROOT = "https://www.googleapis.com/drive/v3/files/"
_MAX_PDF = 100_000_000


class ProviderReadbackError(RuntimeError):
    pass


def transport(request: urllib.request.Request, *, media: bool):
    """No redirect, no retry, bounded metadata and streaming byte hash."""
    parsed = urllib.parse.urlsplit(request.full_url)
    if (parsed.scheme != "https" or parsed.hostname != "www.googleapis.com" or
            parsed.port not in (None, 443) or parsed.username is not None or
            parsed.password is not None or parsed.fragment or
            re.fullmatch(r"/drive/v3/files/[A-Za-z0-9_-]{1,200}", parsed.path) is None or
            request.get_method() != "GET" or request.data is not None):
        raise ProviderReadbackError("Invalid Drive readback target")
    query = urllib.parse.parse_qs(parsed.query, strict_parsing=True)
    expected_query = {"alt": ["media"]} if media else {
        "fields": ["id,mimeType,trashed,appProperties,size"]}
    if query != expected_query:
        raise ProviderReadbackError("Invalid Drive readback fields")
    try:
        with urllib.request.build_opener(google_connections.NoRedirect).open(request, timeout=30) as response:
            if response.status != 200:
                raise ProviderReadbackError("Drive did not confirm the reserved file")
            if not media:
                raw = response.read(16_385)
                if len(raw) > 16_384:
                    raise ProviderReadbackError("Drive metadata exceeded the limit")
                value = google_connections.strict_json(raw.decode("utf-8"))
                if not isinstance(value, dict):
                    raise ProviderReadbackError("Drive metadata is invalid")
                return value
            digest = hashlib.sha256()
            count = 0
            first = response.read(5)
            if first != b"%PDF-":
                raise ProviderReadbackError("Drive bytes are not a PDF")
            digest.update(first)
            count += len(first)
            while True:
                chunk = response.read(min(65_536, _MAX_PDF + 1 - count))
                if not chunk:
                    break
                count += len(chunk)
                if count > _MAX_PDF:
                    raise ProviderReadbackError("Drive PDF exceeded the limit")
                digest.update(chunk)
            return {"sha256": digest.hexdigest(), "size": count}
    except (urllib.error.URLError, TimeoutError, UnicodeError, ValueError,
            json.JSONDecodeError, http.client.IncompleteRead, OSError) as error:
        if isinstance(error, urllib.error.HTTPError):
            error.close()
        raise ProviderReadbackError("Drive readback was not confirmed") from error


class BillingPDFDriveReadback:
    def __init__(self, send=transport):
        self.send = send

    def verify(self, key, reservation, access_token: str) -> str:
        file_id = reservation.drive_file_id
        if (not isinstance(file_id, str) or _ID.fullmatch(file_id) is None or
                not isinstance(reservation.content_digest, str) or
                re.fullmatch(r"[0-9a-f]{64}", reservation.content_digest) is None or
                not isinstance(access_token, str) or not access_token):
            raise ProviderReadbackError("Drive reservation is incomplete")
        headers = {"Authorization": "Bearer " + access_token, "Accept": "application/json"}
        metadata_request = urllib.request.Request(_ROOT + file_id + "?" + urllib.parse.urlencode({
            "fields": "id,mimeType,trashed,appProperties,size"}), headers=headers, method="GET")
        metadata = self.send(metadata_request, media=False)
        expected = {
            "gunnaireSchema": "2",
            "gunnaireAttachmentID": reservation.attachment_id,
            "gunnaireCompanyID": key.company_id,
            "gunnaireDocumentKind": key.document_kind,
            "gunnaireDocumentID": key.document_id,
            "gunnaireSourceDigest": key.source_digest,
            "gunnaireRendererVersion": key.renderer_version,
            "gunnaireContentSHA256": reservation.content_digest,
        }
        if (not isinstance(metadata, dict) or metadata.get("id") != file_id or
                metadata.get("mimeType") != "application/pdf" or metadata.get("trashed") is not False or
                not isinstance(metadata.get("appProperties"), dict) or
                any(metadata["appProperties"].get(name) != value for name, value in expected.items())):
            raise ProviderReadbackError("Drive file identity or revision differs from the reservation")
        declared_size_text = metadata.get("size")
        if (not isinstance(declared_size_text, str) or
                re.fullmatch(r"[0-9]{1,9}", declared_size_text) is None):
            raise ProviderReadbackError("Drive did not report PDF size")
        declared_size = int(declared_size_text)
        if not 5 <= declared_size <= _MAX_PDF:
            raise ProviderReadbackError("Drive PDF size is invalid")
        media_request = urllib.request.Request(_ROOT + file_id + "?alt=media",
            headers={"Authorization": "Bearer " + access_token, "Accept": "application/pdf"}, method="GET")
        result = self.send(media_request, media=True)
        if (not isinstance(result, dict) or result.get("sha256") != reservation.content_digest or
                result.get("size") != declared_size):
            raise ProviderReadbackError("Drive PDF bytes differ from the saved content digest")
        return "https://drive.google.com/file/d/" + file_id + "/view"
