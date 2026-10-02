"""Fixed-origin QuickBooks estimate/invoice email adapter."""
from __future__ import annotations

import json
import re
import urllib.error
import urllib.parse
import urllib.request

try:
    from Backend import billing_publications
    from Backend.billing_provider import NoRedirect
    from Backend.payment_attempts import reference
except ModuleNotFoundError:
    import billing_publications
    from billing_provider import NoRedirect
    from payment_attempts import reference


def transport(request):
    parsed = urllib.parse.urlsplit(request.full_url)
    query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
    path = re.fullmatch(r"/v3/company/[A-Za-z0-9._:-]+/(estimate|invoice|customer)/([A-Za-z0-9._:-]+)(/send)?", parsed.path)
    if (parsed.scheme != "https" or parsed.hostname not in
            {"quickbooks.api.intuit.com", "sandbox-quickbooks.api.intuit.com"}
            or parsed.username is not None or parsed.password is not None
            or parsed.port not in (None, 443) or parsed.fragment or path is None
            or any(len(values) != 1 for values in query.values())
            or (request.get_method() == "GET" and (path[3] is not None or query != {"minorversion": ["75"]}))
            or (request.get_method() == "POST" and (path[1] == "customer" or path[3] != "/send" or set(query) != {"minorversion", "sendTo"}
                or query["minorversion"] != ["75"] or request.data is not None))
            or request.get_method() not in ("GET", "POST")):
        raise billing_publications.failure("invalid_resource", "Unsupported QuickBooks email resource.", 400)
    try:
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=20) as response:
            raw = response.read(1024 * 1024 + 1)
            if len(raw) > 1024 * 1024 or not 200 <= response.status < 300:
                raise ValueError()
            value = json.loads(raw.decode("utf-8"))
            if not isinstance(value, dict):
                raise ValueError()
            return value
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, ValueError, UnicodeDecodeError):
        raise billing_publications.failure("provider_unavailable", "QuickBooks did not confirm this email request.", 502) from None


class DocumentEmailQBOProvider:
    def __init__(self, context, authorize, bearer_loader, send=transport):
        reference(context["realm_id"])
        if context["environment"] not in ("sandbox", "production"):
            raise billing_publications.failure("provider_changed", "Select the original QuickBooks environment.")
        self.context, self.authorize, self.bearer_loader, self.transport = dict(context), authorize, bearer_loader, send
        self.bearer = None

    def request(self, kind, identifier, recipient=None):
        if kind not in ("Estimate", "Invoice", "Customer") or (kind == "Customer" and recipient is not None):
            raise billing_publications.failure("invalid_resource", "Unsupported document email resource.", 400)
        reference(identifier)
        self.authorize()
        if self.bearer is None:
            self.bearer = self.bearer_loader(self.context, "system:qbo-document-email")
        self.authorize()
        origin = ("https://sandbox-quickbooks.api.intuit.com" if self.context["environment"] == "sandbox"
                  else "https://quickbooks.api.intuit.com")
        path = "/v3/company/" + urllib.parse.quote(self.context["realm_id"], safe="")
        path += "/" + kind.lower() + "/" + urllib.parse.quote(identifier, safe="")
        if recipient is not None:
            path += "/send"
        url = origin + path + "?" + urllib.parse.urlencode({"minorversion": "75", **({"sendTo": recipient} if recipient is not None else {})})
        headers = {"Authorization": "Bearer " + self.bearer, "Accept": "application/json"}
        if recipient is not None:
            headers["Content-Type"] = "application/octet-stream"
        request = urllib.request.Request(url, method="POST" if recipient is not None else "GET", headers=headers)
        result = self.transport(request)
        self.authorize()
        value = result.get(kind)
        if not isinstance(value, dict) or value.get("Id") != identifier:
            raise billing_publications.failure("provider_unconfirmed", "QuickBooks returned an incomplete email result.")
        return value

    def read(self, kind, identifier):
        return self.request(kind, identifier)

    def read_customer(self, identifier):
        return self.request("Customer", identifier)

    def send(self, kind, identifier, recipient):
        return self.request(kind, identifier, recipient)
