# Native billing entry-point unification

This candidate follows native publication source `5039252` and workflow
`2669a4d` on PR #18. It removes the remaining native invoice/estimate creation
shortcuts while retaining the full saved-document workflow. It does not merge,
deploy, modify live accounting, collect payment or certify the full application.

## One document lifecycle

| Entry point | Current candidate behavior |
| --- | --- |
| Invoices → New Invoice | Uses the same service/repair/replacement choice as Management. Job-linked invoices inherit the job type; editing an existing invoice preserves its saved type. |
| QuickBooks Management → Create Invoice | Opens the existing full native builder in a focused sheet. Choose service, repair or replacement, customer/property, saved pricebook lines, quantities, authorized adjustments, tax addresses and payment terms. Save locally before shared publication. |
| QuickBooks Management → Create Estimate | Opens the same estimate builder with full lines and proposal options, not a one-line direct accounting request. Local customer/catalog data remains usable offline. |
| Card/ACH collection preparation | Requires the original invoice/customer links. It cannot create, relink or edit either record as an implicit prerequisite to a charge. Billing publication and collection are separate explicit operations. |

The completed management composer retains the original saved document, offers
Billing Review and Sync Saved Document, and cannot create the same document
again. Sync uses `QuickBooksBillingWorkflow`, including its original-attempt
lookup, encrypted proposal journal, exact-price/assignment checks and read-only
recovery. It does not send an email or collect payment. Returning to Management
preserves the Sales workspace and its saved-document publication queues.

An edited, unsaved composer asks whether to keep editing or discard only its
unsaved input; existing records and saved catalog items are retained. A failed
local save retains the same inserted document for Retry Saving Original Draft;
it does not create another model or close while claiming a confirmed save.
This is in-process save-error retention, not proof of a cross-restart unsaved
editor journal. A new composer does not consume an unrelated queued job route.

The focused composer reuses the stack-safe, type-erased builder, excluding the
full overview and collections sections. The normal Invoice overview/builder
split is preserved. Standard Close and nested Back navigation remain available;
the screenshot account-email footer remains hidden under the existing fixture
privacy setting.

Saved work type is exposed as one accessible label/value pair. Notes and the
save action have stable accessibility identifiers. The explicit unsaved-input
confirmation is reserved for leaving edited work; saved/offline status stays
in the form, consistent with [Apple's alert guidance](https://developer.apple.com/design/human-interface-guidelines/alerts).
A standalone invoice no longer claims that an onsite report was created when
there is no associated job.

## Payment and API boundaries

- `QuickBooksPaymentsService` no longer has customer/invoice ensure-or-create
  helpers. Missing, malformed or still-hydrating relationships fail before
  reservation, tokenization or any provider request, with a saved-invoice review
  instruction. It does not make up a default service line or tax result.
- An immutable local invoice/customer snapshot and, when available, the original
  SwiftData model validation are checked through reservation, tokenization and
  the dispatch permit. A changed identity, amount, lines, status, tax or model
  context cannot continue into a charge. The existing shared payment coordinator
  still independently enforces collection access, live provider identity/USD
  balance, open-attempt exclusion and single-use dispatch. It does not borrow
  invoice-writing permission for a collection-only technician.
- Raw `createInvoice`, `updateInvoice` and `createEstimate` transports fail closed
  whenever the shared billing client is installed. Every production data API
  instance installs it. Isolated legacy transport fixtures retain their existing
  nil-client behavior; production cannot fall back to it.
- Explicit email actions on existing QuickBooks records, payments, historical
  imports, walk-in sales receipts, vendor bills and other entity workflows are
  not removed or silently rewritten. This is not a claim that every provider
  credential/proxy/accounting path has completed server migration.

Release compilation also exposed default-argument isolation warnings in
`JobBillingDispatch` and `JobBillingAccessView`. Their shared journal, API,
publisher and identity defaults now resolve inside the main-actor initializer.
Injected fixture dependencies and dispatch authorization remain unchanged;
no isolation check or compiler warning is suppressed. This follows the
[Swift isolation guidance](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/commonproblems/).

## Qualification

Evidence is retained in:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/Billing Entry Points/`.

Final local acceptance passes **1194 logic tests per native platform** and
**10 selected iPad interface journeys** (1204 total in
`PublicationIPadAcceptance.xcresult`, zero failures or skips). The selected
journeys cover existing-invoice and technician item creation/update, repeated
sidebar transitions, the shared work-type choice, job-access confirmation and
lost-reply recovery, Management invoice/estimate cancellation and offline save,
and original native billing cancellation/recovery. Mac evidence is
`FinalQualifiedMacAcceptance.xcresult`.

`FinalUniversalMacRelease.xcresult` passes the unsigned optimized build and
`lipo -verify_arch arm64 x86_64`. Source actor-isolation warnings are gone;
the two architecture links retain the known local optional Metal-toolchain
search-path warning. Backend passes 366 tests and Tools passes 37. Both workflow
files pass actionlint. `SOURCE_SHA256.txt` identifies the exact nine changed
Swift source/test files and unchanged project manifest; the review clone's
app and test directories match the original working source.

Earlier failed runs are retained, not reported as passed. The new harness first
had an attachment-method naming collision and then incorrect standalone item,
notes, work-type and offscreen Sales-picker lookups. The broader 27-journey run
passed 26 but exposed an older invoice-disclosure lookup; its correction also
needed the explicitly named screenshot customer fixture. The original row
identifier is combined by SwiftUI, and non-screenshot fixtures use a different
customer name. The corrected journey verifies the exact invoice edit action,
creates a $25 item, saves the original $214 invoice and returns to Overview.
No app assertion was removed or test skipped. The clean final 10-journey run
includes this correction, both payment rails' identity-change tests, and the
main-actor initializer fixes.

Seven final interface screenshots are retained in `PublicationIPadScreenshots`.
All seven were visually reviewed: the billing states are legible, with no raw
provider payloads or account-email footer visible.
Exact-head hosted checks are required after publishing this candidate; the
green checks on preceding head `2669a4d` do not qualify these source changes.

Backend candidate 2026.09.07.29 still requires separately approved deployment
before distribution of the shared-billing native client. No SwiftData schema,
CloudKit entitlement, signing identity or deployment setting changed here.
Physical iPad/Mac/iPhone convergence, independent staff sharing, signed release
acceptance, provider-backed Tap to Pay, complete sync/reconciliation, credentials,
Mail/Calendar coordination, vendor API access and the remaining competitor-suite
requirements remain part of the unchanged active full-app goal.
