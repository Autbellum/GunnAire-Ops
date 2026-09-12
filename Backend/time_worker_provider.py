"""Read-only, fixed-origin worker verification. Never a payroll/accounting proxy."""
from __future__ import annotations

import re
import urllib.error
import urllib.parse
import urllib.request

try:
    from Backend.time_worker_mappings import failure, reference
    from Backend.qbo_change_capture import strict_json
except ModuleNotFoundError:
    from time_worker_mappings import failure, reference
    from qbo_change_capture import strict_json


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def transport(request):
    try:
        parsed = urllib.parse.urlsplit(request.full_url)
        query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True, strict_parsing=True)
        if (parsed.scheme != "https" or parsed.hostname not in {"quickbooks.api.intuit.com", "sandbox-quickbooks.api.intuit.com"}
                or parsed.username is not None or parsed.password is not None or parsed.port not in (None, 443) or parsed.fragment
                or request.get_method() != "GET" or request.data is not None or query != {"minorversion": ["75"]}
                or not re.fullmatch(r"/v3/company/[A-Za-z0-9._:-]+/(employee|vendor)/[A-Za-z0-9._:-]+", parsed.path)):
            raise ValueError()
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=20) as response:
            raw = response.read(1024 * 1024 + 1)
            if len(raw) > 1024 * 1024 or not 200 <= response.status < 300:
                raise ValueError()
            result = strict_json(raw.decode("utf-8"))
            if not isinstance(result, dict):
                raise ValueError()
            return result
    except (urllib.error.URLError, TimeoutError, ValueError, UnicodeDecodeError):
        raise failure("worker_unavailable", "QuickBooks could not verify this worker. The saved mapping is unchanged.", 502) from None


class TimeWorkerQBOProvider:
    def __init__(self, context, authorize, bearer_loader, send=None):
        reference(context["realm_id"])
        if context["environment"] not in ("sandbox", "production"):
            raise failure("provider_changed", "Choose the original QuickBooks environment.")
        self.context, self.authorize, self.bearer_loader, self.send = dict(context), authorize, bearer_loader, send or transport

    def read(self, kind, identifier):
        if kind not in ("Employee", "Vendor"):
            raise failure("invalid_resource", "Only an existing Employee or Vendor can be reviewed here.", 400)
        reference(identifier)
        self.authorize()
        bearer = self.bearer_loader(self.context, "system:time-worker-review")
        self.authorize()
        origin = "https://sandbox-quickbooks.api.intuit.com" if self.context["environment"] == "sandbox" else "https://quickbooks.api.intuit.com"
        url = origin + "/v3/company/" + urllib.parse.quote(self.context["realm_id"], safe="") + "/" + kind.lower() + "/" + urllib.parse.quote(identifier, safe="")
        request = urllib.request.Request(url + "?minorversion=75", method="GET",
            headers={"Authorization": "Bearer " + bearer, "Accept": "application/json"})
        result = self.send(request)
        self.authorize()
        value = result.get(kind) if isinstance(result, dict) else None
        if not isinstance(value, dict) or value.get("Id") != identifier:
            raise failure("worker_unconfirmed", "QuickBooks returned a different or incomplete worker.")
        return value
