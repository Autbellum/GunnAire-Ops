# Supplier connector onboarding

Last reviewed: 2026-09-05

## Current production-safe status

GunnAire Ops has a versioned, Admin-only server boundary for supplier purchase
orders, but no live supplier adapter is registered. Manual supplier confirmation
remains the authoritative workflow until the business obtains a provider-approved
contract, test configuration, and acceptance evidence. Supplier credentials must
remain on the backend host and must never be stored in the app, source control,
logs, acknowledgements, or screenshots.

## Publicly documented provider paths

| Provider path | Public information verified in Safari | GunnAire status |
| --- | --- | --- |
| Johnstone Supply DirectConnect | Johnstone says consistently formatted data transmissions or file attachments can be converted to orders and directs contractors to their Johnstone account representative. | Commercial onboarding required; no public self-service API specification was found. |
| Johnstone Supply Punch-out | Johnstone describes a customer-specific catalog using standard protocols such as cXML, hosted by Johnstone with account pricing and real-time availability, and directs contractors to their account representative. | Commercial onboarding and customer-specific cXML configuration required. |
| Johnstone Supply ServiceTitan P2P | Johnstone describes an end-to-end ServiceTitan workflow for contractor-specific product/pricing, purchase orders, invoices, accounts-payable reconciliation, and electronic payments. | Published for ServiceTitan rather than as a direct GunnAire API; do not represent it as a GunnAire connector. |
| Lennox procurement | Lennox identifies ServiceTitan as its preferred and exclusive field-service-management partner. Its FAQ says catalog access is available through ServiceTitan, full procurement is waitlisted, and a ServiceTitan account is required. | The published path cannot be represented as a direct GunnAire connector. Separate written Lennox authorization and technical specifications are required before adapter work starts. |

Official sources:

- [Johnstone Supply eCommerce Tools](https://www.johnstonesupply.com/store101/ecommerce-tools)
- [Lennox and ServiceTitan Partner for Seamless Integration](https://www.lennoxpros.com/news/field-service-manangement-hvac)

## Business onboarding packet to request

For Johnstone DirectConnect or Punch-out, ask the GunnAire account representative
for one complete written packet containing:

- the legal business account and every authorized store/branch identifier;
- the approved connection method and complete technical specification;
- non-production endpoints, credentials, certificates, and IP requirements;
- customer catalog, contract pricing, availability, substitution, freight, and tax rules;
- purchase-order, acknowledgement, rejection, cancellation, change, shipment, and invoice schemas;
- idempotency and unknown-outcome recovery rules;
- a test plan, provider acceptance contact, support route, and production activation date.

For Lennox, first request written confirmation that Lennox will authorize a direct
GunnAire integration separate from the published ServiceTitan program. Do not
build or activate a Lennox adapter from the marketing page alone.

## Engineering activation gate

A provider adapter may be added to `SUPPLIER_CONNECTOR_ADAPTERS` only after all of
these checks pass:

1. The provider-approved contract and technical packet are retained by the business.
2. Secrets are installed only in the Render production environment and a separate test environment.
3. The adapter uses GunnAire's stable idempotency key and never blindly resubmits an unknown outcome.
4. Provider acknowledgements reconcile every stable purchase-order line ID, quantity, part number, unit cost, freight, currency, account, and branch.
5. Sandbox tests cover acceptance, rejection, timeout, duplicate request, recovery, price change, partial acknowledgement, malformed response, and credential revocation.
6. A signed staff device proves readiness discovery, one approved test order, recovery, receiving, vendor-bill comparison, and audit evidence.
7. The accounting owner approves the resulting QuickBooks vendor/bill workflow before production purchasing is enabled.

Until this gate is complete, the app intentionally reports the connector as
unavailable and keeps manual confirmation available.
