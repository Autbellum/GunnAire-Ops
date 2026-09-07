# QBO payment workflow lifecycle — 2026-09-06

Status: verified source checkpoint, not production payment acceptance. The full
application goal remains open. Backend candidate: `2026.09.06.21` (not deployed).

## Corrected payment behavior

- ACH debit and refund requests use Intuit's `echecks` resources rather than
  card `charges`. Bank debit payloads no longer include card-only capture or
  currency fields. Refund routing is derived from the original payment method;
  malformed or path-injecting transaction IDs fail before transport.
- Explicit Payments request UUIDs are supported and retained through 429 retries.
  This is a seam for durable attempts, not a durable attempt journal.
- A QBO workflow retains the original workspace/connection operation across
  async suspension, nested tasks and callbacks, including delayed 429 recovery.
  Callback delivery restores that operation before another API call can begin.
  A second API instance or a same-realm replacement connection cannot adopt it.
- Card/ACH processing and refund results carry a final lifecycle check. Invoice
  and payment screens check it immediately before applying provider evidence.
  Accounting follow-up owns the model update and save inside the original
  operation. A late error cannot mark an old Payment as needing attention under
  a new session. Stored-card tokenization and customer linking are one workflow.
- Already-issued refunds create accounting-only RefundReceipts. Neither the
  immediate nor retry payload asks Accounting to process another card payment,
  and ACH refunds are not represented as card processing requests.
- Non-finite, nonpositive, fractional-cent and unsafe-to-convert amounts fail
  before tokenization/refunding. A requested refund cannot exceed the original
  payment amount. Aggregate prior refunds still need authoritative reservation.
- Direct QBO Accounting, Payments, upload and token/charge error paths omit raw
  bodies, headers and underlying network descriptions. They preserve HTTP
  category guidance and warn to reconcile uncertain financial outcomes.
  Arbitrary provider currency/refund-status strings are not echoed. The public
  unavailable-stored-cards behavior remains an empty collection.

The operation is ephemeral and contains no credential. It does not resolve an
external charge whose response was lost, preserve attempts after process death,
or establish independent-iCloud-account support.

## Backend connection race

The refresh handler previously read a grant, called Intuit, then unconditionally
updated the singleton connection. The revoke handler similarly deleted whatever
connection existed after the provider call. Both now compare the exact original
realm, environment, client fingerprint, grant timestamp and encrypted token in
the mutation's WHERE clause. A changed/deleted/rotated grant returns HTTP 409;
an old access token is not returned and a replacement row is not overwritten or
deleted. The successful mutation and its audit event commit atomically.

This protects local grant persistence. It does not undo a provider revocation
already sent, serialize OAuth operations across processes, or recheck a cached
administrator session after the network call. Those server authorization and
external-operation lifetime boundaries remain required before release.

## Verification

- M5 13-inch iPad Simulator, iOS 26.2: **779/779 logic tests passed**.
- Mac Catalyst Debug: **779/779 logic tests passed**.
- Focused workflow/transport suites: **26/26**. Fourteen new test functions cover
  retained task/callback identity, exact card/ACH retry requests, malformed
  identifiers/amounts, actual collection/refund/stored-card service handlers,
  accounting-only payloads, success/error model writes, and late evidence.
  The privacy function exercises six request families against eight
  malformed/HTTP/network outcomes (48 fixture combinations).
- The existing missing-CloudKit-invoice-link test now invokes the public
  follow-up endpoint with an isolated test API and proves zero provider sends.
  It passes in both complete logic suites.
- Backend **93/93**, including **10/10** token-storage tests. Six new tests cover
  actual refresh/revoke handler persistence, every compared grant field,
  same-realm replacement, deletion, provider failure and audit rollback.
  These handler tests mock route authentication; they do not establish
  post-network administrator reauthorization.
- Release/CloudKit/device Tools **37/37**.
- **6/6 focused iPad interface journeys passed**, with zero failures/skips:
  workspace denial/sign-out, primary admin navigation, existing-invoice editing,
  direct Invoice launch, reachable field-payment Handoff and simple Mail.
  Together with logic, the iPad result contains **785/785** passing tests.
- Universal optimized Mac Catalyst Release **built successfully for arm64 and
  x86_64**, confirmed by inspecting the produced binary.

Retained iPad result:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-06/Payment Workflow iPad Logic and Navigation.xcresult`.
The same folder contains `Payment Workflow Mac Logic.xcresult` and the
`payment-workflow-ipad.log`, `payment-workflow-mac-logic.log`,
`payment-workflow-mac-release.log`, `payment-workflow-backend.log` and
`payment-workflow-tools.log` files. Project-manifest SHA-256 is unchanged:
`52ecaabdb59c9d554d286f448a121eecd5a319afd6961bd9de62c3c075b315f7`.
All changed source/test/document files match between the original iCloud
workspace and review clone; staged whitespace checks pass.

All provider transports use fixtures, with no real tokens, charges, refunds,
accounting transactions or customer messages. The initial new test compilation
failed because it referenced a private helper; it was corrected to assert the
public stored-card contract. The corrected focused run passed. Existing Xcode
Metal-toolchain search-path and unsigned AppShortcut/LinkDaemon/ScreenTime
diagnostics are not signed platform acceptance.

Focused result:
`/tmp/GunnAireQBORetryDerivedData/Logs/Test/Test-GunnAire Ops-2026.09.06_22-45-19--0400.xcresult`.

## Required next correctness work

1. Implement a server-authoritative, original-account-scoped attempt journal
   before a charge/refund can be sent. Reserve against simultaneous iPad/Mac/
   iPhone collection, retain stable request IDs and immutable invoice/amount/
   rail evidence, and reconcile uncertain outcomes before allowing another
   attempt. Never persist raw PAN, CVC or bank-account entry data.
2. Add durable refund-receipt recovery and duplicate/conflict detection before
   another accounting create. Current receipt retries still POST a new receipt;
   removing ProcessPayment does not make those retries idempotent.
3. Distinguish accepted/pending ACH submissions from settled funds and reconcile
   returns, failures and partial refunds from authoritative provider events.
   Current local paid/balance handling is not proof of settlement.
4. Complete provider/workspace lifecycle coverage beyond this payment service,
   synchronized-role/legacy-primary-admin handling, server post-network session
   authorization, and OAuth-operation serialization/recovery.
5. Finish OAuth/backend diagnostic privacy. The legacy unused raw refresh-error
   formatter and backend-refresh localized-error path are outside the direct
   request-family corrections above.
6. Correct historical statement cutoffs. Complete signed iPad/Mac/iPhone,
   offline/unsynced-work retention and CloudKit convergence acceptance,
   distribution signing, Production schema review, approved-realm provider
   acceptance, managed Tap to Pay SDK/entitlement and supplier onboarding.

No merge, deployment, real workspace approval, signing change or device install
is authorized by this checkpoint. See [full completion evidence](COMPLETION_EVIDENCE_MATRIX.md)
and [company workspace architecture](CLOUDKIT_WORKSPACE_IDENTITY.md).

## Primary protocol references

- [Intuit eCheck operation routes](https://github.com/intuit/PHP-Payments-SDK/blob/master/src/Operations/ECheckOperations.php)
- [Intuit eCheck request fields](https://github.com/intuit/PHP-Payments-SDK/blob/master/src/Modules/ECheck.php)
- [Intuit ProcessPayment definition](https://github.com/intuit/QuickBooks-V3-PHP-SDK/blob/master/src/Data/IPPCreditChargeInfo.php)
- [Apple task-local scope and inheritance](https://developer.apple.com/documentation/swift/tasklocal)
- [SwiftData model-context container](https://developer.apple.com/documentation/swiftdata/modelcontext/container)

These sources establish protocol and runtime semantics, not live merchant
acceptance or the completeness of GunnAire's business authorization.
