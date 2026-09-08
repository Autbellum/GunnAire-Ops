# Invoice-scoped accounting receipt application

2026-09-08. Native review-branch increment; backend remains the previously
qualified `2026.09.08.39`. This is not a deployment, production payment acceptance,
bank-settlement ledger, or completion of the full HVAC business-suite goal.

## Operator flow

Contactless Payment still performs read-only shared checks. **Update Saved
Invoice** starts a fresh authorized check, then explicitly saves its accounting
balance and evidence to the original invoice. The confirmation stays pinned
above the bottom safe area while the form scrolls, and clears when another check
starts so an earlier success cannot stand in for a later failed request.
The invoice number and balance remain prominent; date/total are optional
details unless the number is missing, when they remain visible for matching.
The original invoice's expanded row offers **Saved accounting check**, including
its number, observation date, balance and applied accounting amounts. That saved
evidence is readable without another provider request.

The action never creates, edits, deletes, refunds or re-sends a `Payment`. It does
not complete a collection assignment. Credits remain accounting applications,
not invented cash. Existing native charge/attempt identifiers, captured amount,
capture time, ACH pending status and notes are retained unchanged. A current
customer statement uses the saved QBO balance, not a second synthetic collection.
The saved check is not a permission to collect again; the contactless app and
other-verified-entry actions recheck their original client and short freshness
window. Offline published invoices cannot open unchecked payment entry from this
guide. Unpublished invoices keep their separate existing cash/check workflow.

## Persistence and conflict contract

One optional `Invoice.quickBooksPaymentReviewJSON` field stores a bounded,
versioned snapshot plus original-document and captured-payment digests. It is
attached to the existing invoice rather than creating another CloudKit record
for each device's copy of the same allocation. All company, customer, invoice,
job, realm/environment and shared-connection checks still belong to the scoped
server read and initiating native client. The local apply additionally requires
unique original customer/invoice mappings, compatible total and tax state, no
retained draft/identity conflict, matching existing payment claims, and no
unresolved local refund. It will not silently reconcile changed or missing
native accounting links by overwriting capture history.

The original client now pins payment history, the previous receipt and sync
timestamp across asynchronous suspension. Applying checks access again immediately
before mutation. Older observations, conflicting observations at the same time,
and downgraded invoice or payment versions are rejected. Repeating an accepted
observation sets the same balance; it never subtracts the payment a second time.
An open attempt remains a collection hold after saving and requires fresh review.

The receipt, balance, status and observation time are saved synchronously in the
original context. A failed save restores only these touched fields, preserving
unrelated draft edits; it does not roll back the whole shared context. Missing,
corrupt or mixed receipt/balance/status/payment fields block collection and
statements. A newer timestamp alone is not proof of a coherent CloudKit merge.

## CloudKit and release boundary

The Development bootstrap candidate is **v27**, adding only optional
`CD_Invoice.CD_quickBooksPaymentReviewJSON` to cumulative v26. Existing record
types/fields/grants remain required by the schema-only manifest. The bootstrap
marker intentionally cannot decode as an applied financial receipt. No signed
bootstrap, Development-to-Production promotion, signing change, physical install,
production deployment or live financial/provider mutation is part of this work.

Schema equality and simulated mixed-field tests do **not** prove signed device
convergence. Older app builds do not understand this receipt guard. Before mixed
version release, the general accounting-import and payment-recovery pipelines
must supply coherent supersession evidence for a previously saved observation;
otherwise this app requires another shared check after those fields change.
Do not remove the receipt or clear financial journals merely to bypass a hold.

This field retains the latest applied accounting observation, not an append-only
historical ledger or a server-signed settlement receipt. A changed/removed remote
allocation replaces the saved observation only when it does not contradict a
native capture; disagreements remain an Accounting reconciliation requirement.
Full historical statements, reversal/return handling, extensive-history paging,
cross-channel collection reservations, real processor acceptance, approved
embedded Tap to Pay and signed iPad/iPhone Handoff/CloudKit acceptance remain
open, together with the full competitor/Google/QBO-item/vendor suite audit.

## Verification evidence

Evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-08/Receipt Reconciliation.gMaZ5t`.

Initial builds exposed a missing SwiftData import and two test-fixture typing/
actor issues; those results are retained. The first executed focused suites pass
24 cases on Mac and iPad. The first iPad save correctly updated the underlying
invoice, but its success message was above the scrolled area. The production
confirmation is pinned outside the scrolling rows; the follow-up test checks
fresh success on both saves before inspecting the updated balance. Full
regression exposed the two old v26 bootstrap test
expectations, now updated to v27 with an added invalid-marker check. Interface
qualification also covers the saved original-invoice disclosure. Further navigation
diagnostics found that identifying the whole invoice disclosure propagated its
identifier to nested buttons: attempting to open the saved check could select
the parent instead. Only the row label is now combined and identified, leaving
its nested actions independently identifiable. The next direct tap exposed a
separate SwiftUI list-row problem: the saved-check tap opened the adjacent
Billing Review destination. The saved disclosure now uses the existing scoped
plain-button disclosure style, and the adjacent link has an explicit plain
button style. The exact technician original-invoice and administrator review
journeys then passed together in `ScopedTap.xcresult`; no assertions were
removed. The full follow-up also asserts that offline published invoices cannot
open verified payment entry and that reading a saved check stays in Invoices.

Final local qualification uses Xcode 26.6 (17F113), serial tests, unsigned builds,
and the 13-inch M5 iPad simulator running iOS 26.2:

| Evidence | Final result |
| --- | --- |
| `ScopedMac.xcresult` | 1,494/1,494 logic cases; no failures or skips |
| `QualifiedInvoice.xcresult` | 1,494 logic and all eight selected UI journeys: 1,502/1,502; no failures or skips |
| Actual-execution verification | Mac logic selector and all nine requested iPad selectors present and passed |
| `ScopedRelease.log` | Unsigned universal Mac Release succeeded; `lipo -verify_arch arm64 x86_64` passed |
| `ToolsReceiptComplete.log` | 56/56 Tools tests passed |
| `BackendFull.log` | 636/636 tests passed against the unchanged candidate backend |
| Workflow lint and whitespace | Both unchanged workflows passed actionlint; `git diff --check` clean |

All 14 final captures in `QualifiedInvoiceImages` were visually reviewed: simple
Mail read/compose/trash and original attachments, both financial-role handoffs,
offline and open-attempt holds, missing-number matching, repeat saved balance,
and the original invoice's accounting disclosure. No account-email footer or raw
provider payload is shown. Fixture addresses in actual Mail content are expected;
these are test captures, not App Store marketing screenshots. The eight UI
journeys include the preceding hosted Mail attachment failure; it passes locally.
`QualifiedSourceHashes.json` pins the 14 final non-document source files. The
Mac runs use the same app source; final iPad evidence also includes the final
UI-only offline and navigation assertions. Local passes are not a substitute
for the new commit's hosted checks, complete Mac UI or physical-device acceptance.

This is not a warning-free whole-app release. Existing actor-isolation warnings
in QuickBooks document upload/recovery defaults and the host's missing optional
Metal-toolchain search path remain recorded in the native build logs. Correct
concurrency boundaries in those existing document paths still need follow-up.

The published predecessor `6cf99fb` has successful Backend, Mac and second iPad
group checks. Its first iPad group failed: Mail attachment accessibility queries
timed out, followed by fourteen active-application accessibility IPC timeouts.
This is not evidence of an invoice crash, nor a fully passing hosted build. The
initial Mail attachment journey is included in this local qualification; new
exact-head hosted acceptance remains a separate gate. The existing 58-selector
workflow is unchanged and already selects the expanded shared receipt journey.

Current primary references inspected in Safari on 2026-09-08:

- [Intuit Invoice API](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/invoice): provider-computed balance, distinct transaction number, targeted linked records and version semantics.
- [Intuit Payment API](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/payment): allocations across invoices and credit memos, unapplied amounts and version semantics.
- [Apple disclosure controls](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls): describe optional information clearly and keep the control close to its details.
