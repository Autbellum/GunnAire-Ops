# Billing identity reconciliation checkpoint

September 7, 2026. Review-only source; no merge, deployment, signing,
CloudKit promotion, physical install, live accounting mutation or customer send.

## Corrected behavior

Invoice and estimate lists now preserve independent local UUIDs, even when
customer, job, date and amount match. Only replicas with the same local UUID
and customer UUID coalesce for display. Visibility filtering happens first.
Refreshed QBO evidence takes precedence over a stale local paid display.

QBO invoice/estimate import uses exact opaque provider IDs and explicit local
UUID lineage, validates customer ownership, and rejects conflicting mappings.
It no longer chooses or merges documents by name, invoice number, date or
amount. Duplicate claims do not delete records, reparent their payments, or
silently pick a winner. Unmarked imports remain separate from similar drafts;
marked imports restore their original UUID. Exact reciprocal job links survive
refresh, but matching dates and prices cannot invent a job association.
Customer import no longer rebinds a same-name customer's QBO identity.

Safe records are saved even when other records need review. The import reports
that partial outcome, persists invoice identity-review status, and stops the
automatic attachment upload on that outcome. A flagged invoice cannot be
edited, published or collected through the covered policies. Invoice attachment
upload additionally requires a hydrated customer and no identity-review flag.
Tracked payment selection requires exactly one matching provider invoice,
matching customer and compatible lineage; document-number fallback is removed.

Reports with ambiguous billing identity show a short review message and a direct
Invoices handoff. Operations counts remain available; financial UI and CSV
export are gated. Customer statements also reject ambiguous aliases. Underlying
report snapshot values remain internal estimates, not authoritative accounting.

## Reproduction and acceptance

The original four regression cases failed before the correction: independent
invoices hidden by display grouping, explicit lineage choosing/merging the wrong
draft, duplicate QBO claims deleting linked history, and document-number-only
payment selection. All four passed after the first correction.

Final fixture-only acceptance:
- iPad M5 13-inch / iOS 26.2: 829 logic tests plus 5 interface journeys pass.
- arm64 Mac Catalyst: 829 logic tests pass.
- Fifteen dedicated billing identity tests cover customer ownership, duplicate
  claims, repeated imports, exact lineage, reciprocal links, payment matching,
  display selection, and report/statement review gates.
- New navigation test opens Reports normally. A command-line UserDefaults
  override initially pinned the route to Reports and masked subsequent route
  changes; the corrected test traverses the real sidebar and review button.
- Equipment QR tests require a built-in four-module white margin and decode
  four deterministic payloads using software image processing. The exported
  single-page fixture was rendered with Poppler and visually inspected.

Native result bundles and logs are retained under:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/`.
See `Billing Identity iPad Acceptance.xcresult` and
`Billing Identity Mac Acceptance.xcresult`.
Parameterized QR tests execute four cases within one logical test.

## Hosted CI correction

The earlier native run at `991b601`
([34085452679](https://github.com/Autbellum/GunnAire-Ops/actions/runs/34085452679))
failed visibly: the iPad QR decoder returned no payload, and the Mac architecture
verification placed its input after the variadic architecture arguments.
Mac logic and its universal Release build succeeded; all four then-selected
iPad UI journeys passed. The separate Backend regression succeeded.

The workflow now places the binary before `-verify_arch arm64 x86_64` and adds
the billing-review interface journey. The QR generator includes its own white
margin before integer scaling, with software rendering. No failing test was
skipped or marked continue-on-error. A fresh hosted run must verify these changes;
local results do not establish hosted success. See [NATIVE_CI.md](NATIVE_CI.md).

The margin follows the QR originator's
[four-module guidance](https://www.qrcode.com/en/howto/code.html).

## Remaining limitations

This is not complete reconciliation or production release readiness:
- Payment-only or incomplete snapshots still need authoritative balance and
  pagination-completeness rules; imported subsets cannot prove a full balance.
- Duplicate payment identity, native ACH method preservation, dated payment
  evidence, and duplicate/malformed lineage-marker validation need follow-up.
- Invoice review is a safety gate, not a complete administrator resolution,
  rebind or superseding-record workflow. Estimate conflicts lack a dedicated
  persisted resolution state.
- Vendor name matching and remaining attachment identity paths are unchanged.
- Higher-level workspace/realm async guards, signed CloudKit replica convergence,
  offline conflict acceptance and historical accounting/versioned invoices remain
  separate work.
- Live provider approval, production deployment, distribution signing, physical
  payment acceptance and full-suite feature parity are not established here.
