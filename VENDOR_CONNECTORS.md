# Supplier connector readiness

The app's **Receipts & Bills** workspace includes an admin-only, job-linked purchase-order trail. It records the selected preferred vendor, supplier part number, quantity, expected cost, freight, creator, and draft-to-ordered-to-received lifecycle before a supplier bill is attached or posted to QuickBooks. It does not submit an order to a supplier by itself.

GunnAire Ops keeps operational inventory and purchase intent separate from supplier and QBO accounting records. A server-side connector owns each supplier credential, account number, catalog agreement, order approval policy, idempotency key, and audit trail. The iOS app may search approved catalogs and submit a purchase request; it must not include a vendor secret or place an order directly.

## Johnstone Supply

Johnstone publicly documents DirectConnect for structured order transmission and Punch-out catalogs using cXML. Either route requires account-manager onboarding and a business-specific catalog/pricing agreement. Enable the relevant `SupplierConnectorKind` only after Johnstone provides the integration specification, test account, branch mapping, and order-approval procedure.

Research revalidated on 2026-08-26: Johnstone describes DirectConnect as an order-transmission channel and describes Punch-out as a customer-specific cXML catalog with real-time pricing and availability. The app must therefore treat branch, negotiated account, and price/availability timestamp as required server-side request context, not as client-side defaults. Source: <https://www-prod-br-od2.johnstonesupply.com/store101/ecommerce-tools>.

## Lennox

Treat Lennox as a partner-gated connector. Obtain dealer/partner approval for the exact data required—catalog, price/availability, purchase order, warranty, rebate, or equipment registration—before implementation. Do not automate the dealer portal or use unofficial endpoints.

Research revalidated on 2026-08-26: Lennox publicly markets current catalog, location-aware pricing/availability, and electronic purchase-order capabilities through its ServiceTitan partnership, with catalog access tied to a ServiceTitan account and procurement still described as a waitlist. This does not establish a public direct API for GunnAire Ops; keep the connector disabled until Lennox supplies a separate approved partner contract. Source: <https://www.lennoxpros.com/news/field-service-manangement-hvac>.

## Required behavior for every enabled supplier

- Keep supplier credentials only in server-side secret storage.
- Bind every catalog query and purchase request to the business tenant and approved supplier account.
- Record request ID, user, job, price/availability timestamp, approval, external order ID, and supplier response.
- Make ordering idempotent; never retry a failed order without checking for an external order ID.
- Require an accounting/owner approval for price overrides, credit use, or purchase-order submission.
