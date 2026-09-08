"""Fixed-origin, upload-only QBO file adapter with exact-marker recovery.

No arbitrary URLs, redirects, file paths, accounting writes, automatic retries,
attachment metadata updates, deletions, or customer-send routes are accepted.
"""
from __future__ import annotations

import hashlib
import re
import urllib.error
import urllib.parse
import urllib.request

try:
    from Backend.catalog_publications import canonical, failure
    from Backend.payment_attempts import reference
    from Backend.qbo_document_uploads import MAX_FILE_BYTES, TYPES
    from Backend.qbo_change_capture import strict_json
except ModuleNotFoundError:
    from catalog_publications import canonical, failure
    from payment_attempts import reference
    from qbo_document_uploads import MAX_FILE_BYTES, TYPES
    from qbo_change_capture import strict_json

IDENTIFIER = r"[A-Za-z0-9._:-]+"
UUID = r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}"
MARKER = r"GunnAire upload " + UUID + r" sha256 [0-9a-f]{64}"
QUERY = r"SELECT \* FROM Attachable WHERE Note = '" + MARKER + r"' STARTPOSITION 1 MAXRESULTS 2"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def transport(request):
    try:
        parsed = urllib.parse.urlsplit(request.full_url)
        if (parsed.scheme != "https" or parsed.hostname not in {"quickbooks.api.intuit.com", "sandbox-quickbooks.api.intuit.com"}
                or parsed.username is not None or parsed.password is not None or parsed.port not in (None, 443) or parsed.fragment):
            raise ValueError()
        prefix = r"/v3/company/" + IDENTIFIER + "/"
        query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True, strict_parsing=True)
        if any(len(value) != 1 for value in query.values()) or query.get("minorversion") != ["75"]:
            raise ValueError()
        if request.get_method() == "GET":
            if request.data is not None:
                raise ValueError()
            if re.fullmatch(prefix + "query", parsed.path):
                if set(query) != {"minorversion", "query"} or not re.fullmatch(QUERY, query["query"][0]):
                    raise ValueError()
            elif not (re.fullmatch(prefix + r"(?:invoice|estimate|bill|payment|salesreceipt|purchase)/" + IDENTIFIER, parsed.path)
                      and set(query) == {"minorversion"} and parsed.path.split("/")[-1] not in (".", "..")):
                raise ValueError()
        elif request.get_method() == "POST":
            if (not re.fullmatch(prefix + "upload", parsed.path) or set(query) != {"minorversion", "requestid"}
                    or not re.fullmatch("ga-file-" + UUID, query["requestid"][0])
                    or not isinstance(request.data, bytes) or not 1 <= len(request.data) <= MAX_FILE_BYTES + 8192
                    or request.get_header("Content-type") != "multipart/form-data; boundary=" + query["requestid"][0]):
                raise ValueError()
        else:
            raise ValueError()
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=30) as response:
            raw = response.read(1024 * 1024 + 1)
            if len(raw) > 1024 * 1024 or not 200 <= response.status < 300:
                raise ValueError()
            value = strict_json(raw.decode("utf-8"))
            if not isinstance(value, dict):
                raise ValueError()
            return value
    except (urllib.error.URLError, TimeoutError, ValueError, UnicodeError):
        raise failure("provider_unavailable", "QuickBooks could not confirm the original file. Check its saved upload status; no automatic replacement was sent.", 502) from None


class DocumentQBOProvider:
    def __init__(self, context, authorize, bearer_loader, send=None):
        reference(context["realm_id"])
        if context["realm_id"] in (".", "..") or context["environment"] not in ("sandbox", "production"):
            raise failure("provider_changed", "Use the original QuickBooks connection.")
        self.context, self.authorize, self.bearer_loader = dict(context), authorize, bearer_loader
        self.send, self.bearer = send or transport, None

    def request(self, resource, query=None, body=None, before_send=None):
        if body is None:
            valid = (resource == "query" and set(query or {}) == {"query"}
                     and isinstance(query["query"], str) and re.fullmatch(QUERY, query["query"]))
            valid = valid or (re.fullmatch(r"(?:invoice|estimate|bill|payment|salesreceipt|purchase)/" + IDENTIFIER, resource)
                              and not query and resource.split("/")[-1] not in (".", ".."))
            if not valid:
                raise failure("invalid_request", "Only original-file recovery and exact transaction reads are supported.", 400)
        elif (resource != "upload" or not callable(before_send) or set(query or {}) != {"requestid"}
              or not isinstance(query["requestid"], str) or not re.fullmatch("ga-file-" + UUID, query["requestid"])
              or not isinstance(body, bytes) or not 1 <= len(body) <= MAX_FILE_BYTES + 8192):
            raise failure("invalid_request", "Only the saved file upload may be dispatched.", 400)
        self.authorize()
        if self.bearer is None:
            self.bearer = self.bearer_loader(self.context, "system:document-upload")
        self.authorize()
        host = "sandbox-quickbooks.api.intuit.com" if self.context["environment"] == "sandbox" else "quickbooks.api.intuit.com"
        url = "https://" + host + "/v3/company/" + self.context["realm_id"] + "/" + resource
        url += "?" + urllib.parse.urlencode({"minorversion": "75", **(query or {})})
        headers = {"Authorization": "Bearer " + self.bearer, "Accept": "application/json"}
        if body is not None:
            if resource != "upload" or not callable(before_send) or set(query or {}) != {"requestid"}:
                raise failure("invalid_request", "Only the saved file upload may be dispatched.", 400)
            headers["Content-Type"] = "multipart/form-data; boundary=" + query["requestid"]
        request = urllib.request.Request(url, method="GET" if body is None else "POST", data=body, headers=headers)
        if body is not None:
            before_send()
            self.authorize()
        try:
            result = self.send(request)
        except (urllib.error.URLError, TimeoutError, OSError, ValueError, UnicodeError):
            raise failure("provider_unavailable", "QuickBooks could not confirm the original file. Check its saved upload status.", 502) from None
        self.authorize()
        return result

    def read_target(self, kind, identifier):
        if not isinstance(kind, str) or kind not in TYPES or reference(identifier) in (".", ".."):
            raise failure("invalid_target", "Choose an exact supported transaction.", 400)
        result = self.request(kind.lower() + "/" + identifier).get(kind)
        if not isinstance(result, dict) or result.get("Id") != identifier:
            raise failure("invalid_target", "QuickBooks did not confirm the selected transaction.")
        return result

    def find(self, note):
        if not isinstance(note, str) or not re.fullmatch(MARKER, note):
            raise failure("invalid_request", "Use the original server upload identity.", 400)
        result = self.request("query", {"query": "SELECT * FROM Attachable WHERE Note = '" + note + "' STARTPOSITION 1 MAXRESULTS 2"}).get("QueryResponse")
        if not isinstance(result, dict):
            raise failure("upload_unconfirmed", "The complete original-file lookup was not confirmed.")
        values = result.get("Attachable", [])
        if (not isinstance(values, list) or len(values) > 2
                or (values and (result.get("startPosition") != 1 or result.get("maxResults") != len(values)))
                or (not values and any(result.get(key, 0) not in (0, None) for key in ("totalCount", "maxResults")))
                or any(not isinstance(value, dict) or value.get("Note") != note for value in values)):
            raise failure("upload_unconfirmed", "QuickBooks returned an incomplete or different file lookup.")
        return values

    def upload(self, metadata, data, request_id, before_send):
        if (not isinstance(request_id, str) or not re.fullmatch("ga-file-" + UUID, request_id)
                or not isinstance(data, bytes) or not 1 <= len(data) <= MAX_FILE_BYTES
                or not isinstance(metadata, dict) or set(metadata) != {"FileName", "ContentType", "Note", "AttachableRef"}
                or not isinstance(metadata.get("Note"), str) or not re.fullmatch(MARKER, metadata["Note"])
                or metadata["Note"].split()[2] != request_id.removeprefix("ga-file-")
                or metadata["Note"].split()[-1] != hashlib.sha256(data).hexdigest()):
            raise failure("invalid_file", "The saved file and operation must match before upload.", 400)
        name, mime = metadata["FileName"], metadata["ContentType"]
        if (not isinstance(name, str) or any(c in name for c in '\r\n"/\\') or not isinstance(mime, str)
                or not re.fullmatch(r"[A-Za-z0-9.+-]+/[A-Za-z0-9.+-]+", mime)):
            raise failure("invalid_file", "The saved filename and content type are invalid.", 400)
        refs = metadata["AttachableRef"]
        if not isinstance(refs, list) or len(refs) > 4:
            raise failure("invalid_target", "The saved transaction links are invalid.", 400)
        for ref in refs:
            entity = ref.get("EntityRef") if isinstance(ref, dict) else None
            if (not isinstance(entity, dict) or set(ref) != {"EntityRef", "IncludeOnSend"} or set(entity) != {"type", "value"}
                    or not isinstance(entity["type"], str) or entity["type"] not in TYPES or ref["IncludeOnSend"] is not False):
                raise failure("invalid_target", "An upload cannot change accounting records or request customer delivery.", 400)
            reference(entity["value"])
        boundary = request_id
        if ("--" + boundary).encode() in data:
            raise failure("invalid_file", "The original file conflicts with its multipart boundary; keep it for review.", 400)
        start = (f'--{boundary}\r\nContent-Disposition: form-data; name="file_metadata_01"; filename="attachment.json"\r\n'
                 'Content-Type: application/json; charset=UTF-8\r\n\r\n' + canonical(metadata) +
                 f'\r\n--{boundary}\r\nContent-Disposition: form-data; name="file_content_01"; filename="{name}"\r\n'
                 f'Content-Type: {mime}\r\n\r\n').encode("utf-8")
        body = start + data + f'\r\n--{boundary}--\r\n'.encode()
        result = self.request("upload", {"requestid": request_id}, body, before_send).get("AttachableResponse")
        if (not isinstance(result, list) or len(result) != 1 or not isinstance(result[0], dict)
                or result[0].get("Fault") is not None or not isinstance(result[0].get("Attachable"), dict)):
            raise failure("upload_unconfirmed", "QuickBooks did not confirm the single original file.")
        return result[0]["Attachable"]
