# Durable payment-attempt coordination

Backend candidate: `2026.09.06.22`. Review-only; not deployed. The full
GunnAire Ops application goal remains incomplete.

## What changed

New card, ACH and refund workflows in `QuickBooksPaymentsService` now reserve
an immutable attempt on the business server before tokenization or sending.
Every current native collection screen uses this service. The server issues a
one-time dispatch permission and retains the original request UUID and client
transaction ID across devices, retries, app termination and lost responses.

The journal accepts current Apple/Google application sessions, not the legacy
shared API token. Admin and Accounting users can collect/refund. Technicians
can collect only against their own active assignment and remaining allowance.
Authorization is rechecked inside each state-changing database transaction,
including after provider reads. Completed assignments permit their original
collector to reconcile existing attempts, but never grant another collection.
Cancelled/revoked assignments and sessions do not permit recovery.

Invoice UUID matching tolerates native uppercase UUIDs without rewriting
existing assignment data. Verified journal collections consume assignment
allowance even when the shared payment upload has not yet arrived.

A partial unique index prevents two open attempts for the same business,
QuickBooks realm, environment and provider invoice, even if devices have
different local invoice UUIDs. A retained balance ceiling prevents a stale QBO
invoice response from reopening an already-consumed amount. An entirely unsent,
cancelled history can accept a freshly verified edited invoice balance.
Dispatch reads the invoice again after reservation/tokenization.

## State and evidence

`reserved → sending → confirmed → completed`

- Only `reserved` can be cancelled without sending.
- A lost send/begin response is retained as `sending` or `unknown`; it never
  expires into permission to resend.
- Confirmation stores a candidate provider reference before network I/O, then
  verifies the original provider record's ID, client transaction ID, cents,
  currency and supported status through a server GET.
- Completion verifies a QBO Payment or RefundReceipt's customer, amount, full
  recovery marker and, for payments, exact invoice allocation.
- Refund reservation verifies the original provider/accounting identities and
  cumulative journal refunds. Pending/declined bank funds are not treated as
  settled refundable funds. External refund history still requires provider
  acceptance; it is not inferred from incomplete local records.
- Confirmation, state transitions and audit events commit together. Internal
  OAuth refresh uses grant-bound compare-and-set with an atomic audit.
- GET verification uses fixed Intuit HTTPS origins, bounded JSON responses and
  no redirects. Errors do not return raw provider bodies, bearer tokens or
  card/bank details.

The journal does **not** itself send a financial transaction. The existing
native sender receives a one-time permission, uses the exact reserved request
ID, and remains bound to its initiating workspace/provider operation. An old
success or error cannot switch into a replacement connection.

## Native recovery and interface

Payments → History → **Review interrupted payments**, or **Payment review**
beside an outstanding invoice, opens one invoice-scoped sheet. It shows plain
status/amounts and keeps technical references in optional review details.

The user may release an unsent reservation or verify/restore an existing
transaction. Recovery never resends a charge/refund. If a provider response was
lost before an ID was captured, the office must locate the original transaction
in QuickBooks and supply its reference; the server verifies it before use.

Refund accounting now reads the complete paginated RefundReceipt collection
before creation, checks full marker/customer/amount evidence, rejects duplicate
or conflicting matches, and uses a stable accounting request ID. Payment
accounting retains its existing full-snapshot recovery.

Optional CloudKit-compatible Payment fields retain the attempt UUID and provider
status separately from queue/accounting labels. Refund local IDs now equal their
journal attempt IDs. Recovery upserts by this UUID in the current local store.
An ACH `PENDING` flag survives shared-queue updates and is displayed as pending
settlement, not proof of cleared funds.

## Verification

- M5 13-inch iPad simulator, iOS 26.2: **792/792 logic tests and 7/7 focused UI
  journeys passed (799 total), zero failures/skips**.
- Mac Catalyst Debug: **792/792 logic tests passed**, zero failures/skips.
- Optimized Mac Catalyst Release built successfully; the produced executable
  contains both **arm64 and x86_64**. The pre-existing external Metal-toolchain
  search-path warning remains. Unsigned test hosts emit AppShortcut/LinkDaemon/
  ScreenTime diagnostics; these are not signed platform acceptance.
- **124/124 Backend tests**: includes 23 journal HTTP tests and eight fixed
  provider-reader tests in addition to the existing integration suite.
- **37/37 release/CloudKit/device tool tests**.
- The focused native iteration passed 26/26 before the final whole-suite run;
  the final suite adds a regression for a late error after account replacement.
- UI journeys cover primary admin navigation, direct Invoice launch, existing
  invoice line-item editing, simple Mail actions, field Handoff controls,
  focused Payments workspaces and the new review sheet returning to History.
  This is not a fresh whole-UI or physical-device acceptance run.
- All changed files match the original iCloud workspace and review clone.
  The project manifest remains unchanged (SHA-256
  `52ecaabdb59c9d554d286f448a121eecd5a319afd6961bd9de62c3c075b315f7`).

Retained under
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-06`:

- `Payment Journal iPad Logic and Navigation.xcresult`
- `Payment Journal Mac Logic.xcresult`
- `Payment Journal Review UI.xcresult` and `payment-journal-review.png`
- `payment-journal-ipad.log`, `payment-journal-mac-logic.log`,
  `payment-journal-mac-release.log`, `payment-journal-backend.log`,
  `payment-journal-tools.log`

Original test results:

- `/tmp/GunnAireQBORetryDerivedData/Logs/Test/Test-GunnAire Ops-2026.09.06_23-52-09--0400.xcresult`
- `/tmp/GunnAireQBORefreshMac/Logs/Test/Test-GunnAire Ops-2026.09.06_23-52-10--0400.xcresult`

Tests use temporary databases, isolated application sessions and explicit
in-memory/provider fixtures. No live charge, refund, accounting record,
customer communication, deployment, signing change or physical install was
performed. Earlier test failures were corrected request-count assertions after
the added refund lookup and a reader test's audit-table name. Their logs remain
under `/tmp/gunnaire-native-payment-journal-focused-20260906.log` and
`/tmp/gunnaire-payment-journal-backend-full-20260906.log`.

The initial review-screen capture was rejected because of a clipped landscape
app-window image. Waiting for rotation did not correct that capture. The final
UI-only follow-up passes **1/1**, asserts a settled landscape window and captures
display coordinates with `XCUIScreen.main.screenshot()`. Its image was visually
verified: the full sheet, controls and explanatory text are intact, with no
account email. These test-only changes do not change app behavior. Final result:
`/tmp/GunnAireQBORetryDerivedData/Logs/Test/Test-GunnAire Ops-2026.09.07_00-01-50--0400.xcresult`.

## Required next work and release gates

This is not a claim of complete payment safety or complete application readiness.

1. **Server-owned sending / provider credentials:** native direct QBO bearer
   access remains broader than the journal permissions. The journal cannot
   prevent a modified/older client or external merchant tool bypassing it.
   Technician OAuth refresh/access and an approved embedded Tap to Pay SDK
   remain part of the authorization/platform work.
2. **Accounting dispatch coordination:** complete reads plus stable request IDs
   improve recovery, but accounting creation does not yet have a server-owned
   one-time send permit. Concurrent recovery and provider idempotency-retention/
   eventual-consistency behavior need stronger acceptance evidence.
3. **ACH settlement and returns:** submission is distinguished from settlement,
   but automated later status updates, returns/reversals, partial-refund state
   coverage and financial-report inclusion rules are not complete. Reconfirming
   an already-confirmed journal currently retains its initial status.
4. **Cross-channel collection:** manual cash/check and the external contactless
   provider path are not yet reserved in this journal. External transactions
   between a verified balance read and send cannot be serialized by this app.
5. **Recovery administration:** unknown outcomes never auto-expire. Reconnected
   grants require explicit original-merchant review; a safe approval/rebinding
   workflow, proof-based decline resolution and paginated historical listing
   beyond the current 100-record invoice response still need implementation.
6. **CloudKit acceptance:** optional model fields compile in the current schema;
   signed upgrade/migration, independent-device convergence, duplicate local
   replica records and offline/revoked-access behavior require real acceptance.
7. **Production promotion:** review the full diff, back up the persistent SQLite
   database (including both new journal/limit tables), deploy and verify .22
   before distributing this native candidate. No signing/provider secrets or
   production settings were changed. A rollback must retain the journal and
   disable old uncoordinated collection paths, not erase holds or ship an older
   sender while unresolved attempts exist.
8. Other full-suite gates remain: historical statement cutoffs, other retained
   workflow/store lifetimes, Google/provider acceptance, CloudKit Production,
   signed iPad/Mac/iPhone validation, supplier onboarding and top-ten feature
   acceptance from `COMPLETION_EVIDENCE_MATRIX.md`.

## Primary implementation references

- [Intuit charge operations](https://github.com/intuit/PHP-Payments-SDK/blob/master/src/Operations/ChargeOperations.php)
- [Intuit eCheck operations](https://github.com/intuit/PHP-Payments-SDK/blob/master/src/Operations/ECheckOperations.php)
- [Intuit Payments SDK request-ID contract](https://github.com/intuit/PHP-Payments-SDK)

These establish explicit request IDs and GET-by-provider-ID resources, not an
unbounded safe-replay guarantee or a general lookup by client transaction ID.
