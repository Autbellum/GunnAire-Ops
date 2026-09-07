"""Fixed-origin QBO adapter for shared billing publication.

Credentials are supplied by the existing server grant-refresh callback, never
by an application payload. Current catalog evidence authorizes field prices.
"""
from __future__ import annotations

import json
import re
import urllib.error
import urllib.parse
import urllib.request

try:
    from Backend.billing_publications import bounded_text, document_values, failure, reference
    from Backend.catalog_publications import canonical
except ModuleNotFoundError:
    from billing_publications import bounded_text, document_values, failure, reference
    from catalog_publications import canonical


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def transport(request):
    try:
        parsed = urllib.parse.urlsplit(request.full_url)
        if (parsed.scheme != "https" or parsed.hostname not in {"quickbooks.api.intuit.com", "sandbox-quickbooks.api.intuit.com"}
                or parsed.username is not None or parsed.password is not None or parsed.port not in (None, 443) or parsed.fragment):
            raise ValueError()
        if not re.fullmatch(r"/v3/company/[A-Za-z0-9._:-]+/(?:query|preferences|(?:invoice|estimate)(?:/[A-Za-z0-9._:-]+)?|(?:item|customer|companyinfo)/[A-Za-z0-9._:-]+)", parsed.path):
            raise ValueError()
        query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
        if any(len(value) != 1 for value in query.values()) or set(query) - {"query", "minorversion", "requestid"}:
            raise ValueError()
        method = request.get_method()
        if method not in ("GET", "POST") or (method == "POST" and not re.search(r"/(invoice|estimate)$", parsed.path)):
            raise ValueError()
        if method == "POST" and (set(query) != {"minorversion", "requestid"} or not re.fullmatch(r"ga-(?:invoice|estimate|update)-[0-9a-f-]{36}", query["requestid"][0])):
            raise ValueError()
        if method == "GET" and set(query) != ({"minorversion", "query"} if parsed.path.endswith("/query") else {"minorversion"}):
            raise ValueError()
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=20) as response:
            raw = response.read(1024 * 1024 + 1)
            if len(raw) > 1024 * 1024 or not 200 <= response.status < 300:
                raise ValueError()
            value = json.loads(raw.decode("utf-8"))
            if not isinstance(value, dict):
                raise ValueError()
            return value
    except (urllib.error.URLError, TimeoutError, ValueError, UnicodeDecodeError):
        raise failure("provider_unavailable", "QuickBooks could not confirm the billing request. Review the original attempt before retrying.", 502) from None


class BillingQBOProvider:
    def __init__(self, context, authorize, bearer_loader, send=None):
        reference(context["realm_id"])
        if context["environment"] not in ("sandbox", "production"):
            raise failure("provider_changed", "Select the original QuickBooks environment.")
        self.context, self.authorize, self.bearer_loader = dict(context), authorize, bearer_loader
        self.send, self.bearer = send or transport, None

    def request(self, resource, query=None, document=None, before_send=None):
        read_allowed = re.fullmatch(r"(?:query|preferences|(?:invoice|estimate|customer|item|companyinfo)/[A-Za-z0-9._:-]+)", resource)
        if (document is None and not read_allowed) or (document is not None and (resource not in ("invoice", "estimate") or before_send is None)):
            raise failure("invalid_resource", "Unsupported billing resource.", 400)
        self.authorize()
        if self.bearer is None:
            self.bearer = self.bearer_loader(self.context, "system:billing-publication")
        self.authorize()
        origin = "https://sandbox-quickbooks.api.intuit.com" if self.context["environment"] == "sandbox" else "https://quickbooks.api.intuit.com"
        url = origin + "/v3/company/" + urllib.parse.quote(self.context["realm_id"], safe="") + "/" + resource
        url += "?" + urllib.parse.urlencode({"minorversion": "75", **(query or {})})
        request = urllib.request.Request(url, method="GET" if document is None else "POST",
            data=canonical(document).encode() if document is not None else None,
            headers={"Authorization": "Bearer " + self.bearer, "Accept": "application/json", "Content-Type": "application/json"})
        if document is not None:
            if len(request.data) > 1024 * 1024:
                raise failure("invalid_document", "The billing proposal is too large to publish safely.", 400)
            before_send()
        result = self.send(request)
        self.authorize()
        return result

    def read(self, kind, identifier):
        if kind not in ("Invoice", "Estimate", "Customer", "Item", "CompanyInfo"):
            raise failure("invalid_resource", "Unsupported billing read.", 400)
        reference(identifier)
        value = self.request(kind.lower() + "/" + urllib.parse.quote(identifier, safe="")).get(kind)
        if not isinstance(value, dict) or (kind != "CompanyInfo" and value.get("Id") != identifier):
            raise failure("provider_unconfirmed", "QuickBooks returned an incomplete or different record.")
        reference(value.get("Id"))
        return value

    def documents(self, kind):
        if kind not in ("Invoice", "Estimate"):
            raise failure("invalid_resource", "Unsupported billing comparison.", 400)
        def count():
            value = self.request("query", {"query": "SELECT COUNT(*) FROM " + kind}).get("QueryResponse")
            total = value.get("totalCount") if isinstance(value, dict) else None
            if type(total) is not int or not 0 <= total <= 100000:
                raise failure("documents_incomplete", "The complete accounting document list could not be verified.")
            return total
        total, values, seen = count(), [], set()
        # Smaller pages keep ordinary 750-line documents below the response cap;
        # exceptionally large pages stop safely rather than truncating a census.
        for start in range(1, total + 1, 25):
            result = self.request("query", {"query": f"SELECT * FROM {kind} ORDERBY TxnDate STARTPOSITION {start} MAXRESULTS 25"}).get("QueryResponse")
            page = result.get(kind) if isinstance(result, dict) else None
            if (not isinstance(page, list) or len(page) != min(25, total - start + 1)
                    or result.get("startPosition") != start or result.get("maxResults") != len(page)):
                raise failure("documents_incomplete", "Accounting document pages changed or were incomplete.")
            for value in page:
                if not isinstance(value, dict):
                    raise failure("documents_incomplete", "QuickBooks returned an incomplete document.")
                identifier = reference(value.get("Id"))
                if identifier in seen:
                    raise failure("documents_incomplete", "QuickBooks repeated a document during comparison.")
                seen.add(identifier)
                values.append(value)
        if count() != total:
            raise failure("documents_incomplete", "Accounting documents changed during comparison.")
        return values

    def preflight(self, document):
        preferences = self.request("preferences").get("Preferences")
        if not isinstance(preferences, dict):
            raise failure("preferences_required", "Verify company currency and tax settings before billing.")
        currency = preferences.get("CurrencyPrefs")
        if (not isinstance(currency, dict) or not isinstance(currency.get("HomeCurrency"), dict)
                or currency["HomeCurrency"].get("value") != "USD" or type(currency.get("MultiCurrencyEnabled")) is not bool):
            raise failure("currency_review", "Verify the original company's US-dollar billing settings.")
        company = self.read("CompanyInfo", self.context["realm_id"])
        if company.get("Country") not in ("US", "USA"):
            raise failure("country_review", "This billing workflow supports the original US business only.")
        customer = self.read("Customer", document["CustomerRef"]["value"])
        if customer.get("Active") is not True:
            raise failure("customer_review", "Review the inactive accounting customer before new billing.")
        if currency["MultiCurrencyEnabled"] and (document.get("CurrencyRef") != {"value": "USD"}
                or not isinstance(customer.get("CurrencyRef"), dict) or customer["CurrencyRef"].get("value") != "USD"):
            raise failure("currency_review", "Confirm the document and customer currency explicitly.")
        taxable = any(line.get("SalesItemLineDetail", {}).get("TaxCodeRef", {}).get("value") == "TAX" for line in document["Line"])
        if taxable:
            tax = preferences.get("TaxPrefs")
            if not isinstance(tax, dict) or tax.get("UsingSalesTax") is not True or tax.get("PartnerTaxEnabled") is not True:
                raise failure("tax_review", "Review automated sales-tax setup before publishing taxable lines.")
            origin = document.get("ShipFromAddr")
            destination = document.get("ShipAddr")
            for address in (origin, destination):
                if not isinstance(address, dict) or not all(isinstance(address.get(key), str) and address[key].strip() for key in ("Line1", "City", "CountrySubDivisionCode", "PostalCode")):
                    raise failure("tax_review", "Confirm the sale origin and service address for automated tax.")
        evidence = {}
        for identifier in sorted({line["SalesItemLineDetail"]["ItemRef"]["value"] for line in document["Line"] if line["DetailType"] == "SalesItemLineDetail"}):
            item = self.read("Item", identifier)
            if item.get("Active") is not True or item.get("Type") not in ("Service", "NonInventory", "Inventory"):
                raise failure("item_review", "Review the sold item's current accounting status.")
            evidence[identifier] = {key: item[key] for key in ("Id", "Active", "Type", "UnitPrice", "Taxable") if key in item}
        return evidence

    def write(self, kind, document, request_id, before_send):
        if kind not in ("Invoice", "Estimate") or not isinstance(document, dict) or not callable(before_send):
            raise failure("invalid_resource", "Unsupported billing publication.", 400)
        prefix = "ga-update-" if "Id" in document else "ga-" + kind.lower() + "-"
        if not isinstance(request_id, str) or not re.fullmatch(re.escape(prefix) + r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", request_id):
            raise failure("invalid_request", "The saved accounting request identity is invalid.", 400)
        if "Id" in document and kind != "Invoice":
            raise failure("invalid_resource", "Estimate updates require a separate reviewed contract.", 400)
        note = bounded_text(document.get("PrivateNote"), 4000, multiline=True)
        publication_ids = re.findall(r"^GunnAire Publication: ([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})$", note, re.MULTILINE)
        document_ids = re.findall(r"^GunnAire " + kind + r" ID: ([0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12})$", note, re.MULTILINE)
        if len(publication_ids) != 1 or len(document_ids) != 1:
            raise failure("invalid_request", "The saved accounting operation has no server lineage.", 400)
        if request_id != prefix + (publication_ids[0] if "Id" in document else document_ids[0].lower()):
            raise failure("invalid_request", "The accounting operation identity does not match its saved request.", 400)
        user_fields = dict(document)
        user_fields["PrivateNote"] = "\n".join(line for line in note.splitlines() if not line.startswith(("GunnAire Publication:", "GunnAire " + kind + " ID:")))
        automatic_fields = {}
        if "Id" not in document:
            if user_fields.pop("EmailStatus", None) != "NotSet":
                raise failure("invalid_request", "Saving a document cannot request customer delivery.", 400)
            automatic_fields["EmailStatus"] = "NotSet"
            if kind == "Invoice":
                for flag in ("AllowOnlineACHPayment", "AllowOnlineCreditCardPayment", "AllowOnlineAffirmPayment", "AllowOnlinePayPalPayment"):
                    if user_fields.pop(flag, None) is not False:
                        raise failure("invalid_request", "Saving an invoice cannot enable automatic customer delivery.", 400)
                    automatic_fields[flag] = False
        validated = document_values(user_fields, kind, "update" if "Id" in document else "create")
        validated.update(PrivateNote=note, **automatic_fields)
        value = self.request(kind.lower(), {"requestid": request_id}, validated, before_send).get(kind)
        if not isinstance(value, dict):
            raise failure("provider_unconfirmed", "QuickBooks returned incomplete billing evidence.")
        return value
