# Supplier connector readiness

The app's **Receipts & Bills** workspace includes an admin-only, job-linked purchase-order trail. It records the selected preferred vendor, every line's item/SKU/supplier-part identity, quantity, expected and accepted cost, freight, creator, and draft-to-ordered-to-received lifecycle before a supplier bill is attached or posted to QuickBooks. A draft cannot become Ordered until an administrator records the supplier channel, acknowledgement/order reference, optional branch, accepted per-line/freight costs, actor, and time; receiving is blocked until that evidence exists. This manual confirmation records an order accepted through an approved external channel—it does not submit an order to a supplier by itself.

GunnAire Ops keeps operational inventory and purchase intent separate from supplier and QBO accounting records. A server-side connector owns each supplier credential, account number, catalog agreement, order approval policy, idempotency key, and audit trail. The iOS app may search approved catalogs and submit a purchase request; it must not include a vendor secret or place an order directly.

## Implemented connector boundary

Backend source `2026.08.30.16` provides provider-neutral ordering contract version 2 without pretending that a supplier connection exists:

- `GET /api/supplier-connectors` is Admin-only and returns readiness, capabilities, and onboarding links without returning credentials, account identifiers, or configuration values.
- `POST /api/supplier-connectors/orders` is Admin-only, requires a stable `Idempotency-Key`, accepts a strict purchase-order snapshot with one to one hundred stable-ID lines, rejects extra or secret-shaped fields, and supports USD only. Every line requires a bounded item name, internal SKU and/or supplier part number, positive quantity, and nonnegative expected unit cost.
- The adapter registry is empty by default. An unavailable connector is rejected before an order-attempt row is created.
- The server permits only one active or accepted connector submission per local purchase order. A repeated key can replay only the retained acknowledgement for the same exact request hash.
- An interrupted or uncertain provider result is never submitted again. The adapter must reconcile the original key through `recover_order`; otherwise the attempt remains visibly unknown for supplier-account review.
- Only a validated, sanitized acknowledgement can mark the attempt accepted. The server and app require the exact requested line-ID set, no duplicate or foreign lines, exact quantities, compatible supplier part numbers, valid per-line confirmed costs, purchase-order identity, supplier/connector match, currency, timestamp, original Admin actor, external order ID, and idempotency key before storing immutable evidence and changing the local draft to Ordered. A mismatch remains an unknown provider outcome and never becomes a partial acceptance.
- Discovery exposes the contract version. An active legacy version-1 adapter is shown as upgrade-required and cannot submit through the version-2 app.

In **Receipts & Bills → Purchasing → Confirm Order**, the app shows this path only for a server-reported contract-v2 ready connector that matches the selected vendor and when every line has an internal SKU or supplier part number. The existing manual portal/email/phone/counter confirmation remains available when no approved adapter is active. Installing an adapter is a deployment change and still requires supplier onboarding, reviewed credentials, a provider test account, and production authorization. Production currently remains backend `2026.08.30.15`; source `.16` has not been deployed and no adapter is registered.

## Johnstone Supply

Johnstone publicly documents DirectConnect for structured order transmission and Punch-out catalogs using cXML. Either route requires account-manager onboarding and a business-specific catalog/pricing agreement. Enable the relevant `SupplierConnectorKind` only after Johnstone provides the integration specification, test account, branch mapping, and order-approval procedure.

Research revalidated on 2026-08-28: Johnstone describes DirectConnect as an order-transmission channel and describes Punch-out as a customer-specific cXML catalog with real-time pricing and availability. The app must therefore treat branch, negotiated account, and price/availability timestamp as required server-side request context, not as client-side defaults. Source: <https://www.johnstonesupply.com/store101/ecommerce-tools>.

## Lennox

Treat Lennox as a partner-gated connector. Obtain dealer/partner approval for the exact data required—catalog, price/availability, purchase order, warranty, rebate, or equipment registration—before implementation. Do not automate the dealer portal or use unofficial endpoints.

Research revalidated on 2026-08-28: Lennox publicly markets current catalog, location-aware pricing/availability, and electronic purchase-order capabilities through its ServiceTitan partnership, with catalog access tied to a ServiceTitan account and procurement still described as a waitlist. This does not establish a public direct API for GunnAire Ops; keep the connector disabled until Lennox supplies a separate approved partner contract. Source: <https://www.lennoxpros.com/news/field-service-manangement-hvac>.

## Required behavior for every enabled supplier

- Keep supplier credentials only in server-side secret storage.
- Bind every catalog query and purchase request to the business tenant and approved supplier account.
- Record request ID, user, job, price/availability timestamp, approval, external order ID, and supplier response.
- Make ordering idempotent; never retry a failed order without checking for an external order ID.
- Require an accounting/owner approval for price overrides, credit use, or purchase-order submission.
- Let only the server-side adapter identify an order as an approved-connector acceptance. A user-entered confirmation cannot claim connector delivery.
