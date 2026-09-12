# Shared milestone invoice identity — candidate 2026.09.08.37

## Problems reproduced

Two devices previously generated different random invoice UUIDs for one saved
project milestone. The shared publisher protected each invoice UUID separately,
so that protection did not exclude two charges for the same stage. Long operator
notes could also truncate the trailing milestone reference.

Native end-to-end tests then exposed a separate real defect: the edit lock for
progress invoices also blocked their first shared QuickBooks publication. The
retained CorrectedMac result has that failing reproduction. Editing stays locked;
only initial shared publication of the saved allocation has the new opt-in.
Linked, paid, signed, finalized and reconciliation-protected invoices remain
protected. Lost-response recovery uses the existing immutable original proposal.

## Contract and authoritative state

- New stage invoices derive a version-8 UUID from SHA-256 of the fixed
  `gunnaire-milestone-invoice-v1` namespace and lowercase milestone UUID. The
  independent reference vector is pinned in tests. Creation date, computer,
  billing sequence and display title do not change that identity.
- Existing random invoice IDs are never rewritten. Payment, attachment, job and
  CloudKit relationships remain attached to their original records.
- Invoice proposals optionally carry `projectMilestoneID`, with the original
  `serviceCallID` required. It participates in the encrypted intent and digest.
  Older proposal hashes are not changed, nor are old journals reconstructed.
- A short `GunnAire Milestone ID:` reference leads new private notes. Server and
  native response validation also understand the previous full project-billing
  reference. Disagreement, duplicate markers and malformed references require
  review. User notes cannot impersonate either app-owned prefix. The native
  shared proposal reserves 200 characters for server lineage within QBO's note
  limit; full user notes and sold snapshots remain on the local original.
- The additive `billing_milestone_index` indexes original publication UUID,
  payload hash and optional milestone UUID. Encrypted publication history remains
  authoritative. Lazy backfill validates legacy payloads and also indexes ordinary
  documents, avoiding repeated decryption of the entire history. No financial
  records are deleted or merged by backfill.
- Within the existing SQLite `BEGIN IMMEDIATE` reservation and dispatch
  transactions, a company/realm/environment/milestone can belong to only one
  invoice UUID. Removing its reference or moving its customer/job is rejected.
  Cancellation releases an unsent proposal, not that invoice's durable identity;
  the same invoice may prepare a revised never-sent proposal.
- Two pre-existing invoice UUIDs claiming one milestone are an explicit history
  conflict, not an arbitrary first-winner selection. Issued/uncertain original
  lines, quantities, prices, posting dates, currency and tax addresses cannot be
  replaced by another stage proposal.
- Current office authorization or an exact office-reviewed technician grant is
  required for milestone publication. Ordinary job assignment alone is not
  approval to issue project progress billing. Current company, customer, job,
  session and QBO-grant checks still apply.
- Provider census checks the old/new milestone references before sending a
  create. An existing provider-only invoice under another local ID requires
  Existing Links review rather than another accounting write. Unknown dispatch
  outcomes retain their consumed permit and recover only the original.

Intuit's [Invoice API](https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities/invoice)
documents ordinary Invoice/GroupLineDetail transactions, its private-note limit,
and that native QBO Progress Invoicing is not supported through the API. This
implementation publishes ordinary invoices allocated from the approved project;
it does not invent a provider progress-invoicing endpoint or send customer mail.
The primary API reference was inspected in Safari on September 8, 2026.

## Native recovery and navigation

The existing context GET accepts the optional milestone UUID and returns
`milestoneIdentityVersion: 1` plus the original publication/invoice identity when
one exists. Authorization runs before history lookup and every awaited provider
read is revalidated. Wrong customer, job, company, realm or environment cannot
be used to discover another original.

The client verifies capability version and response identity. An older server
cannot silently accept an unprotected new milestone. For an already linked
customer, lookup happens before prerequisite writes; an unmapped customer still
uses the existing verified customer-link workflow before invoice publication.
The final publication context and atomic server reservation close the race after
the read. No direct-accounting fallback is added.

Billing Review offers "Open original milestone invoice" when that exact record
has arrived locally. It shows the saved allocation, with components one disclosure
away, and an existing Billing Review link. Back navigation returns to the original
review/invoice workspace. Missing CloudKit records have a check-again state;
ambiguous/wrong-context records instead require review. No draft, attachment,
payment, UUID or frozen price is replaced by that handoff.

Retained screenshot review exposed a lifecycle defect that the first green UI
run missed: returning from the original invoice reused a cancelled workflow and
displayed a raw `Swift.CancellationError`. Each visit now owns a fresh workflow;
navigation cancels its old owner, stale completions cannot update a later visit,
and the original navigation identity remains present while the child is open.
The strengthened test returns, presses Check again, and asserts both the original
invoice link and absence of an error. The final screenshots confirm the saved
allocation, the clean return screen, and the missing-record state without an
account-email footer or internal proposal data.

## Qualification and rollout

Retained local evidence:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-08/Shared Milestones.TjHa1c`.
Final qualification against the frozen `NavigationSource.sha256` (15 source/test
files, verified unchanged after all processes finished):

- `NavigationMac.xcresult`: 1,390 logic tests across 40 suites pass.
- `NavigationIPad.xcresult`: the same 1,390 logic tests plus all seven selected
  iPad UI journeys pass, including both new milestone handoffs, accepted-invoice
  recovery, unsent cancellation, bundle milestone creation, Invoice and Mail.
  Exported summary/test trees confirm 1,390 and 1,397 actual passing test cases,
  with every requested selector present and no failures or skips.
- `NavigationUniversalMac.log`: unsigned Mac Catalyst Release succeeds; the
  resulting executable separately verifies both arm64 and x86_64 architectures.
- `VersionedBackend.log`: all 564 tests pass in 59.959 seconds, including 18 new
  milestone identity, authorization, concurrency, recovery and local HTTP tests.
- `Tools.log`: all 51 tests pass. The proposed 41-journey native CI workflow
  passes actionlint; hosted execution remains separate from local qualification.
- `NavigationScreens` and `NavigationMissingScreens`: all three final milestone
  screenshots were visually inspected. Earlier compiler/publication-lock failures
  and the screenshot exposing cancellation remain retained, not overwritten.

These native checks used Xcode 26.6, Mac Catalyst on macOS 26.6.2, and the
13-inch M5 iPad Simulator running iPadOS 26.2. They are not physical-device or
production-provider acceptance. The preceding published workflow commit is
`c1df9ff`; this source candidate requires its own exact-head hosted checks.

No production deployment, accounting write, payment, CloudKit schema promotion,
signing change or physical installation is part of this checkpoint. Deploy only
after backing up the existing encrypted database and key, validating restoration,
qualifying the exact candidate, and obtaining explicit deployment authorization.
The schema change is additive and originals remain readable by older code, but
an older billing writer does not enforce the new index. Rollback must pause new
milestone publication; do not run mixed old/new writers and claim protection.

## Remaining full-suite acceptance

This is not proof that the application is finished. In particular:

- Signed physical iPad/Mac CloudKit delivery, concurrent model creation,
  duplicate-model reconciliation and mixed-version client behavior remain
  unverified. Stable application UUIDs are not CloudKit uniqueness constraints.
- A second independently created draft may have a different billing date or
  snapshot revision. It is not silently adopted as the server original. Complete
  reconciliation of those local drafts, attachments and financial reporting
  remains required; merely opening the original is not a merge.
- Legacy provider invoices whose milestone reference was already completely
  absent/truncated cannot be identified from nonexistent evidence. They require
  accounting reconciliation; no fuzzy amount/name matching is used.
- More general feasible cent redistribution, previously issued allocation
  histories, provider-import editing and a real approved QBO sandbox transaction
  remain required. All provider mutations in these tests use isolated fixtures.
- Full top-ten-competitor coverage, remaining Google/vendor/access features and
  physical iPad-to-iPhone Handoff/Tap to Pay remain in the objective.
