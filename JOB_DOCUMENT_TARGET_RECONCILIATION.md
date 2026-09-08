# Job document targets and CloudKit closeout state

This checkpoint continues the full business-suite goal; it does not establish
whole-app, signed-device, provider, or production readiness.

## Corrected behavior

- The automatic file linker follows a job's saved invoice and estimate links
  before considering legacy back-references. A present but unavailable link
  cannot fall through to another transaction. Creation date is not identity.
- Without a stored link, only an exact, unique customer/job back-reference may
  fill an absent attachment link. An approved estimate's operational job link
  remains supported separately from its original estimate visit.
- New files can follow a valid reviewed milestone receipt to the original
  invoice. Existing file invoice/estimate ownership and the job's historical
  link are not rewritten. Current payment records participate in reconciliation.
- Duplicate local document IDs, conflicting provider IDs, duplicate file
  objects, missing customer relationships, and foreign customer/job targets
  are not automatic upload permission. Repeating the same object in a query
  plus a newly generated-file list still queues it only once.
- Receipt defaults retain the correct Invoice/Estimate type and ID together.
  Changing the job or transaction type clears the prior target. Lookup replies
  require the original request, type, current administrator, and captured
  QuickBooks connection. Connection changes invalidate the displayed target.
- Documentation Queue distinguishes pending customer/invoice/payment records,
  billing review, and a genuinely empty visible queue. It no longer claims all
  invoices are paid because unresolved rows are absent. Missing job customers
  keep their records while document actions wait. A billing-review message
  offers a direct Invoices handoff, without collection of an unverified balance.

No new stored model field, entitlement, signing setting, backend route, or
provider endpoint was introduced. Automatic linking remains separate from
the durable account/realm authorization required for provider dispatch.

## Provider contract

Intuit's [Attach images and notes](https://developer.intuit.com/app/developer/qbo/docs/workflows/attach-images-and-notes)
was read in Safari on September 8, 2026. Its contract uses the transaction's
entity type and previously fetched ID in `AttachableRef.EntityRef`. A file
upload without that metadata only places the file in the attachment list;
it is not evidence of a transaction association. Existing attachments are
linked through their metadata, not by recreating a financial transaction.

## Retained evidence

Evidence root:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-08/Document Targets.1NYAX9`

- `BeforeFix.xcresult`: all six new identity regressions fail, with eleven
  assertions reproducing newest-document selection, unresolved-link fallthrough,
  missing-customer adoption, duplicate-ID selection, and different-job uploads.
- `TargetFix.xcresult`: 1,419 logic tests pass. Further review added estimate,
  retained-draft, pending-customer, duplicate-provider/file, and queue-state tests.
- `FinalMac.xcresult`: the intermediate 1,426-test suite passes. Its summary
  and execution tree were verified, not just the console success message.
- `IPad.xcresult`: 1,426 logic tests and seven of eight UI journeys pass. The
  receipt test incorrectly selected the first same-customer visit. The retained
  video frame `ReceiptBeforeFix.png` shows the later, unbilled visit, not a lost
  saved invoice link. This is not reported as a passing full run.
- The receipt test now selects the exact job identity, uses the existing stable
  invoice/estimate-visit fixtures and a dedicated synthetic estimate provider
  reference, and keeps its exact type/ID/clearing assertions. No lookup or upload
  is sent to a real provider by these UI tests.
- All 52 Tools tests and both workflow actionlint checks pass.
- `QualifiedMac.xcresult` passes 1,427 logic tests in 43 suites. The corresponding
  iPad bundle passes the same 1,427 logic tests and all nine selected UI journeys
  (1,436 executions). Both exact execution trees were checked. The matching
  unsigned universal Mac build passed with arm64 and x86_64 verified.
- Visual inspection of all four new UI screenshots caught a stale stored Paid
  label beneath the correct review warning. The row now uses reconciled status,
  and the review-handoff journey requires the visible `$189.00 • Review` label.
  The preceding green tests therefore did not alone establish UI acceptance.
- `AcceptedMac.xcresult` passes all 1,427 logic tests in 43 suites. The final
  `AcceptedIPad.xcresult` passes 1,427 logic tests and all nine selected UI
  journeys (1,436 executions). The accepted summaries and complete execution
  trees were verified; all four final screenshots were inspected, including
  the corrected `$189.00 • Review` row and the Estimate attachment target.
- `AcceptedUniversalMac.log` ends in `BUILD SUCCEEDED`; the unsigned Release
  binary contains both arm64 and x86_64. No signed-device acceptance is implied.
- `AcceptedSource.sha256` binds the ten accepted source/test files.
  `FinalSource.sha256` and `QualifiedSource.sha256` retain the earlier states.
  All twelve scoped source/test/documentation paths match the original iCloud
  project; its empty index and 216 unrelated changed files are preserved.
- PR #18 already contains the preceding source/workflow at `9e8ab2a`, with
  44 UI selectors. At this checkpoint its Backend and Mac checks passed, while
  the iPad check was still running. The prepared workflow adds the four new UI
  journeys (48 total), preserves every prior selector, and passes actionlint.
  Publication and hosted verification of this checkpoint are separate from
  these local results; the PR's exact head and checks are authoritative.

## Remaining work and release gates

The legacy receipt retry queue still persists raw transaction targets under an
unscoped UserDefaults key. It needs durable company/realm/grant ownership,
protected file retention, and explicit recovery of uncertain uploads. The legacy
automatic upload callback also needs retained file/context/authority validation,
save-failure handling, and shared upload intent deduplication. These are not
made safe merely by selecting the correct initial local invoice.

Receipt job visibility, post-network storage actions, generated-file reuse,
and remaining direct file/estimate consumers require continued access/lifecycle
review. In particular, `BillingDocumentsView.invoice(for:)` still falls back to
customer/amount/description matching; repeated service is not durable lineage.
Visual review also leaves the existing cramped multi-action document rows,
long workflow-help section, and administrator-facing raw transaction controls
for a broader interaction pass; these screens are not claimed to be flawless.

Physical/mixed-version CloudKit arrival and convergence, approved Google/QBO
provider acceptance, supplier agreements, complete top-ten-suite coverage,
whole-interface/accessibility/performance acceptance, and signed iPad/iPhone
Handoff/Tap to Pay remain required. Current simulator fixtures do not prove
these gates. No merge, deployment, schema promotion, signing change, physical
installation, accounting mutation, payment, or customer send occurred.
