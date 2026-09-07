# QBO balance and payment snapshot reconciliation

September 7, 2026. This is a review-branch implementation checkpoint, not a
deployment, live financial acceptance run, or complete application release.

## Authority and corrected behavior

QBO's Invoice Balance is the accounting source for an imported invoice. A
Payment result can be partial and cannot establish the invoice's net balance
after other payments, credits or adjustments. Intuit describes Balance as a
read-only remaining amount and Payment as activity applied to one or more
sales transactions ([Invoice properties](https://static.developer.intuit.com/sdkdocs/qbv3doc/ippdotnetdevkitv3/html/dcff3707-a41b-25d9-4209-fb92bc9f18ff.htm),
[Payment properties](https://static.developer.intuit.com/sdkdocs/qbv3doc/ippdotnetdevkitv3/html/0b501ee6-1a8e-88b0-9bfb-df31903d89d6.htm)).
The current interactive Intuit entity pages did not expose usable reference
content during this check; the linked official SDK references supplied the
field semantics. No endpoint or authorization scope changed.

- Payment-only import preserves the last reported balance, status and balance
  timestamp. It saves safe payment allocations and reports incomplete
  reconciliation instead of subtracting only that response's payments.
- Missing, non-finite, negative or out-of-range balances cannot replace a saved
  value. Invoice total decoding rejects missing, non-finite or negative totals
  rather than treating an invalid response as a free invoice.
- A fresh valid invoice response restores the accounting balance and clears the
  balance-review state, subject to identity and tax checks.
- The normal sync reads invoice balances after payments. Only resource arrays
  that successfully loaded during the current run are eligible for local import;
  retained screen data from a failed resource is not imported as fresh.
- Pagination returns every unique page or fails the whole resource. Repeated
  provider identities are no longer silently reduced to the first value, and
  a later-page failure cannot return the earlier pages as success.
- Duplicate local payment-allocation claims preserve both records. Repeated
  remote payment identities cannot choose an arbitrary allocation amount.
- Native payment capture amount, timestamp, rail, pending provider status and
  identifiers are retained. An accounting allocation that disagrees with the
  original captured amount requires review instead of overwriting the capture.
  A QBO processor/charge ID does not imply card: ACH remains ACH, and a paper
  check is not classified as an electronic bank payment.

## User flow and data continuity

The existing invoice/report review flow handles incomplete balances. Collection,
invoice edits, customer statements and financial CSV export are gated while
review is required. The app does not advertise Paid from an unconfirmed saved
zero. Reports retain usable operational counts and the direct Review Invoices
handoff, with no new dashboard, technical response dump or navigation level.
The invoice row shows Review needed, and its expanded details offer Review in
QuickBooks only to an authorized administrator. Collection stays disabled until
the relevant evidence is reconciled.

The numeric outstanding-balance helper still exposes a last-known value for
internal display/operational calculations. It is not fresh accounting evidence
while reconciliation is required. The covered commitment/export policies must
be consulted, not bypassed by checking that numeric value alone.

No stored SwiftData field, CloudKit schema, entitlement, signing configuration
or project manifest changed. Existing records are not deleted or merged.
A failed/partial sync preserves evidence and supports a subsequent refresh.

## Verification

Seven of the original eight focused cases failed on the prior implementation,
with 22 assertions documenting guessed balances, lost timestamps/ACH pending
state, check misclassification and arbitrary duplicate-payment mutation.
The first corrected focused run passed 14 logical tests. The first broad run
passed 847 logical tests on both platforms before the final strict-total decoder
case was added. Final current-source acceptance on Xcode 26.6 (17F113):

- iPad Pro 13-inch (M5), iOS 26.2 simulator: **849/849 logic tests and 6/6
  focused interface journeys pass**, with no failures or skips. The result
  bundle reports 855 logical tests and 863 parameter-expanded executions.
- arm64 Mac Catalyst: **849/849 logic tests pass**, with no failures or skips
  (857 parameter-expanded executions).
- An unsigned optimized Mac Catalyst Release build succeeds, and
  `xcrun lipo <executable> -verify_arch arm64 x86_64` verifies both architectures.
  Subsequent edits changed only tests/documentation, not this app source.
- The six interface journeys cover Invoice launch, simple Mail, current
  statement generation, statement review, billing-identity review, and the
  unconfirmed-balance Reports → Invoices → QuickBooks handoff. The last
  journey verifies that collection and financial CSV export remain disabled
  while review is required. It is local focused coverage; the existing hosted
  workflow still selects the other five journeys.

Evidence is retained under
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-07/`:
`QBO Balance iPad Acceptance.xcresult`,
`QBO Balance Mac Acceptance.xcresult`, the matching acceptance logs, and
`QBO Balance Universal Release.log`. Tests use the existing
`GunnAire Ops` scheme with `CODE_SIGNING_ALLOWED=NO` and serial execution.

The dedicated tests include injected HTTP transports, not live API calls:
500-record first pages, repeated IDs on a later page, later-page failure, and a
complete unique multi-page payment response. Positive invoice-balance recovery
and split-payment allocation coverage remain present.

The existing hosted workflow at `61df19b` passes Mac and all five iPad UI
journeys, but fails its Vision QR assertion under the VM's inference constraint.
The simulator-only supported-CPU selection and actual-image software decode
fallback are documented in [NATIVE_CI.md](NATIVE_CI.md);
it is not represented as a hosted pass before a new run completes.

## Remaining work

This does not yet establish a dated accounting ledger, full historical
statements, changed/deleted/reallocated payment tombstones, ACH settlement and
return handling, administrator conflict resolution, or atomic cross-resource
snapshots. Higher-level sync workflows still need their initiating workspace
and provider operation retained across the entire orchestration, not only each
request/page. Signed CloudKit multi-device/offline acceptance, production
provider approval, physical payment/Handoff acceptance and distribution remain
separate release gates. Earlier statements that only external gates remained
were too broad and are superseded by these explicit internal gaps.
