# Invoice-scoped accounting receipt application

## Sync and recovery follow-up, 2026-09-08

The current increment connects saved observations to the existing QuickBooks
Management sync and original payment recovery/follow-up. Once those workflows
save their original records, they perform fresh scoped reads for invoices that
already have a saved accounting check. Successful reads atomically replace that
observation with the current document/payment digests and provider balance. Bulk
resource pages and capture responses never fabricate a shared observation.
Ordinary invoices without a saved observation do not incur this additional read.

An unavailable or conflicting follow-up retains the prior observation and its
collection/statement hold. It does not relabel a confirmed captured payment as
failed, erase its accounting ID, or offer to send it again. The existing recovery
and payment status surfaces carry the remaining review message. Releasing an
unsent reservation also refreshes any saved hold from fresh server evidence;
cancellation alone does not invent a paid or clear state.

The original invoice's existing **Saved accounting check** disclosure now has a
read-only **Refresh accounting check** action. The disclosure remains reachable
when the invoice is paid or held, and remains visible when an old observation no
longer matches the local document. This removes the discovered dead end where
collection eligibility prevented opening the guide that the error recommended.
The action never opens a payment form or another workspace; its status stays
beside the saved evidence. Scene/view changes cancel the initiating refresh, and
each request rechecks the original business, client, invoice and payment state.

Recovery and unsent cancellation also freeze the original invoice/customer,
payment digest and prior receipt across journal and accounting awaits. A local
edit, deleted invoice, remapped customer or newer payment/receipt writer prevents
the older result from being applied. This preserves original server recovery
evidence without committing it into a changed local record.

The audit also found a concrete sign mismatch: original-attempt refund recovery
created a negative `Payment.amount`, whereas the other refund entry points and
statement/invoice policies use a positive amount with `isRefund` determining the
direction. New recovery records now use that existing convention. Existing
negative historical records are not rewritten by this increment and still need
reviewed reconciliation; no ledger migration or live refund occurred.

Qualification evidence is retained under
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-08/Receipt Sync.C3UmYm`.
The first compile's escaping-check closure diagnostic is retained and corrected.
The next focused run passed all new cases but caught an existing detached,
receipt-free accounting fixture entering the new context requirement; the
receipt-free path now remains a no-op. No existing test assertion was removed.
The corrected focused suites pass **49/49** on both Mac and iPad, covering actual
import, repeated charge/refund recovery, unsent cancellation, offline follow-up,
changed originals, storage failure and original connection boundaries.

The first full iPad run (`CompleteIPad.xcresult`) passed all 1,503 logic cases and
eight of nine UI journeys. The added original-invoice refresh assertion failed
because the disclosure's accessibility identifier propagated into its contents;
the retained recording shows the button was visible, not an invoice app crash.
Moving the group identifier onto its label preserves the child action/status
identifiers. `NavigationCorrected.xcresult` then passes the unchanged refresh,
confirmation and stay-in-Invoices assertions. No assertion was removed or
replaced by a coordinate tap. The final source also passes all 1,503 Mac logic
cases, and the actual-execution verifier confirms the full requested target.
`FinalIPad.xcresult` passes all 1,503 logic cases and all nine selected UI journeys
(1,512 total, zero failures/skips). Its actual-execution tree verifies all ten
requested target/method selectors. The original invoice opening, simple Mail,
attachment preview/forward, recovery and contactless handoffs pass. All 15 final
screenshots were visually reviewed: original-invoice refresh confirmation remains
beside its evidence, and no account-email footer or raw Mail payload is shown.
`FinalRelease.log` records a successful unsigned universal Mac Release build;
`lipo -verify_arch arm64 x86_64` passes for the resulting executable.

All 56 Tools tests and both workflow lint checks pass. The workflow is exactly
the published `58ca6be` version: 58 existing named UI journeys split into disjoint
29-journey iPad groups, complete logic targets, universal Mac Release, read-only
permissions and retained result evidence. The new direct refresh assertion is
inside an already-selected journey; no workflow weakening was needed.
`FinalSourceHashes.json` freezes all nine changed non-document source paths.
The preceding failed/superseded runs remain available rather than being counted
as final acceptance. Current provider semantics were rechecked in Safari
against the Intuit Invoice API linked below. The backend, schema candidate v27,
signing and existing workflow selectors are unchanged.

Original-project preflight verifies all 11 scoped paths, 248 unrelated changed
files and its empty index. A further 296 other tracked native/project/Tools/
Backend paths are byte-identical between the review checkout and original. Only
the scoped increment is intended for copy-back and commit; unrelated changes and
untracked Python caches are excluded. No merge, deployment, real provider or
financial mutation, customer message, signing/schema change or physical install
was performed by this qualification.

This does not prove coherent handling by older app builds, the unused legacy
ContentView import method, every billing publication path, server historical
ledger/settlement/return handling or signed CloudKit delivery. The full suite's
provider, physical Tap to Pay/Handoff, Google/item/vendor and release gates remain
open. At the latest prepublication read, exact published predecessor `6036f2f`
has successful Backend and Mac checks; both iPad jobs are still running. Its
successes do not qualify a later commit. Four existing document-concurrency
warnings and the optional Metal toolchain search-path warning remain tracked;
this checkpoint does not claim a warning-free build.

## Original receipt checkpoint

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
