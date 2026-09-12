"""Fixed QBO TimeActivity create/read surface; no updates, payroll or deletes."""
from __future__ import annotations

import re
import urllib.error
import urllib.parse
import urllib.request
from datetime import date

try:
    from Backend.time_worker_provider import NoRedirect
    from Backend.time_worker_mappings import failure, reference, canonical_uuid
    from Backend.qbo_change_capture import strict_json
    from Backend.catalog_publications import canonical
except ModuleNotFoundError:
    from time_worker_provider import NoRedirect
    from time_worker_mappings import failure, reference, canonical_uuid
    from qbo_change_capture import strict_json
    from catalog_publications import canonical


QUERY = re.compile(r"SELECT \* FROM TimeActivity ORDERBY TxnDate STARTPOSITION ([1-9][0-9]{0,4}) MAXRESULTS 100")


def validate_create(document, request_id):
    required = {"TxnDate", "NameOf", "Hours", "Minutes", "Description"}
    if (not isinstance(document, dict) or not required <= set(document)
            or set(document) - required - {"EmployeeRef", "VendorRef", "CustomerRef", "ItemRef"}
            or document["NameOf"] not in ("Employee", "Vendor")
            or document["NameOf"] + "Ref" not in document or {"EmployeeRef", "VendorRef"} <= set(document)
            or not isinstance(request_id, str) or not request_id.startswith("ga-time-")):
        raise failure("invalid_time", "Only the reviewed original time-create payload can be sent.", 400)
    identifier = canonical_uuid(request_id.removeprefix("ga-time-"))
    if request_id != "ga-time-" + identifier:
        raise failure("invalid_time", "Use the exact original time request identity.", 400)
    for key in ("EmployeeRef", "VendorRef", "CustomerRef", "ItemRef"):
        if key in document:
            if not isinstance(document[key], dict) or set(document[key]) != {"value"}:
                raise failure("invalid_time", "Use verified shared time references only.", 400)
            reference(document[key]["value"])
    try:
        if not isinstance(document["TxnDate"], str) or date.fromisoformat(document["TxnDate"]).isoformat() != document["TxnDate"]:
            raise ValueError()
    except ValueError:
        raise failure("invalid_time", "Keep the original approved posting date.", 400) from None
    description = document["Description"]
    if (type(document["Hours"]) is not int or not 0 <= document["Hours"] <= 8760
            or type(document["Minutes"]) is not int or not 0 <= document["Minutes"] <= 59
            or not 0 < document["Hours"] * 60 + document["Minutes"] <= 8760 * 60
            or not isinstance(description, str) or len(description) > 4000
            or any((ord(c) < 32 and c not in "\n\t") or ord(c) == 127 for c in description)
            or description.splitlines().count("GUNNAIRE-TIME-PUBLICATION:" + identifier.upper()) != 1):
        raise failure("invalid_time", "Review the approved duration, note and original publication identity.", 400)


def transport(request):
    try:
        parsed = urllib.parse.urlsplit(request.full_url)
        query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True, strict_parsing=True)
        if (parsed.scheme != "https" or parsed.hostname not in {"quickbooks.api.intuit.com", "sandbox-quickbooks.api.intuit.com"}
                or parsed.username is not None or parsed.password is not None or parsed.port not in (None, 443) or parsed.fragment
                or query.get("minorversion") != ["75"]):
            raise ValueError()
        prefix = r"/v3/company/[A-Za-z0-9._:-]+/"
        allowed = False
        if request.get_method() == "GET" and request.data is None:
            if re.fullmatch(prefix + r"(employee|vendor|customer|item|timeactivity)/[A-Za-z0-9._:-]+", parsed.path):
                allowed = set(query) == {"minorversion"}
            elif re.fullmatch(prefix + "query", parsed.path) and set(query) == {"minorversion", "query"} and len(query["query"]) == 1:
                allowed = QUERY.fullmatch(query["query"][0]) is not None
        elif request.get_method() == "POST" and re.fullmatch(prefix + "timeactivity", parsed.path):
            allowed = (set(query) == {"minorversion", "requestid"} and len(query["requestid"]) == 1
                       and re.fullmatch(r"ga-time-[0-9a-f-]{36}", query["requestid"][0]) is not None
                       and isinstance(request.data, bytes) and len(request.data) <= 32768)
        if not allowed:
            raise ValueError()
        if request.get_method() == "POST":
            validate_create(strict_json(request.data.decode("utf-8")), query["requestid"][0])
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=20) as response:
            raw = response.read(4 * 1024 * 1024 + 1)
            if len(raw) > 4 * 1024 * 1024 or not 200 <= response.status < 300:
                raise ValueError()
            result = strict_json(raw.decode("utf-8"))
            if not isinstance(result, dict) or "Fault" in result:
                raise ValueError()
            return result
    except (urllib.error.URLError, TimeoutError, ValueError, UnicodeDecodeError):
        raise failure("time_provider_unavailable", "QuickBooks could not confirm this request. Keep the original time proposal for recovery.", 502) from None


class TimeQBOProvider:
    def __init__(self, context, authorize, bearer_loader, send=None):
        reference(context["realm_id"])
        if context["environment"] not in ("sandbox", "production"):
            raise failure("provider_changed", "Choose the original QuickBooks environment.")
        self.context, self.authorize, self.bearer_loader, self.send = dict(context), authorize, bearer_loader, send or transport
        origin = "https://sandbox-quickbooks.api.intuit.com" if context["environment"] == "sandbox" else "https://quickbooks.api.intuit.com"
        self.base = origin + "/v3/company/" + urllib.parse.quote(context["realm_id"], safe="") + "/"

    def request(self, path, *, query=None, payload=None):
        self.authorize()
        bearer = self.bearer_loader(self.context, "system:time-publication")
        self.authorize()
        values = {"minorversion": "75", **(query or {})}
        result = self.send(urllib.request.Request(self.base + path + "?" + urllib.parse.urlencode(values),
            data=canonical(payload).encode() if payload is not None else None,
            method="POST" if payload is not None else "GET",
            headers={"Authorization": "Bearer " + bearer, "Accept": "application/json", "Content-Type": "application/json"}))
        self.authorize()
        if not isinstance(result, dict) or "Fault" in result:
            raise failure("provider_unconfirmed", "QuickBooks did not confirm the original time request.")
        return result

    def read(self, kind, identifier):
        if kind not in ("Employee", "Vendor", "Customer", "Item", "TimeActivity"):
            raise failure("invalid_resource", "This time review cannot access that QuickBooks resource.", 400)
        reference(identifier)
        result = self.request(kind.lower() + "/" + urllib.parse.quote(identifier, safe=""))
        value = result.get(kind)
        if not isinstance(value, dict) or value.get("Id") != identifier:
            raise failure("provider_unconfirmed", "QuickBooks returned a different or incomplete reference.")
        return value

    def activities(self):
        # Check the complete bounded list, not just today's date: older device
        # versions may have posted this same local marker on another date.
        values, seen, total = [], set(), None
        for start in range(1, 10001, 100):
            result = self.request("query", query={"query": f"SELECT * FROM TimeActivity ORDERBY TxnDate STARTPOSITION {start} MAXRESULTS 100"})
            response = result.get("QueryResponse")
            if not isinstance(response, dict) or set(response) - {"TimeActivity", "startPosition", "maxResults", "totalCount"}:
                raise failure("provider_unconfirmed", "QuickBooks returned an incomplete time page.")
            page = response.get("TimeActivity", [])
            count = response.get("maxResults", 0)
            position = response.get("startPosition", start)
            if (not isinstance(page, list) or len(page) > 100 or type(count) is not int or count != len(page)
                    or type(position) is not int or position != start
                    or ("totalCount" in response and (type(response["totalCount"]) is not int or response["totalCount"] < len(page)))):
                raise failure("provider_unconfirmed", "QuickBooks did not confirm a complete ordered time page.")
            for value in page:
                if not isinstance(value, dict):
                    raise failure("provider_unconfirmed", "QuickBooks returned an invalid time record.")
                identifier = reference(value.get("Id"))
                if identifier in seen:
                    raise failure("provider_unconfirmed", "The QuickBooks time list changed during pagination. No new time was sent.")
                seen.add(identifier)
            values.extend(page)
            if "totalCount" in response:
                if total is not None and total != response["totalCount"]:
                    raise failure("provider_unconfirmed", "The QuickBooks time count changed during review.")
                total = response["totalCount"]
            if len(page) < 100:
                if total is not None and total != len(values):
                    raise failure("provider_unconfirmed", "QuickBooks returned only part of the time history. No new time was sent.")
                return values
        raise failure("time_history_review", "The QuickBooks time history exceeds this review limit. No new time was sent.")

    def create(self, document, request_id):
        validate_create(document, request_id)
        result = self.request("timeactivity", query={"requestid": request_id}, payload=document)
        value = result.get("TimeActivity")
        if not isinstance(value, dict):
            raise failure("provider_unconfirmed", "QuickBooks did not return the original time record.")
        return value
