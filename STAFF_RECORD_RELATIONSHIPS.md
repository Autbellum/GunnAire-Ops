# Staff record relationship preflight

Candidate, September 9, 2026. This extends the complete 32-model persistence
coverage in `STAFF_FULL_MODEL_COVERAGE.md`. It is a linked-record validation
boundary, not completed staff synchronization or a business-access grant.

## Implemented

Every persisted UUID outside the model's primary ID has an explicit disposition:
an exact model-kind/UUID reference, a proposal-group identity, or retained
operation/receipt evidence. Every owning SwiftData relationship is classified
separately. The classifications are checked against all 32 actual schema entities,
including each UUID/optional UUID attribute and each codec's owning references.
New unclassified UUIDs cannot silently become unconstrained links.

The graph validates the entire supplied batch before returning a value. It rejects
unknown kinds, invalid codec fields, duplicates and missing exact-kind references.
Connected customer contexts cannot contain two customers. This applies across
jobs, properties, equipment, agreements, estimates/invoices, payments, requests,
milestones, files, communication, expenses and tasks. Separate technician, vehicle
and invoice context checks protect time-off/availability, fleet attachments and
refund lineage. Proposal groups cannot span customers.

Company resources are not incorrectly treated as customer-owned: catalog items,
form templates and crew can be used across customers. Historical visit/property
and fleet-assignment snapshots need not equal the current equipment location or
vehicle assignment. Their exact recorded values are retained. A refund references
the original non-refund payment on the same invoice; validation neither calculates
payment success nor issues a refund. Known time-off/block, receipt/claim, follow-up
and milestone/invoice back-links cannot name a different original record.
Explicit job invoice links must retain the invoice's recorded job. Estimate links
accept their diagnostic visit, scheduled work order or genuinely standalone
proposal; a missing diagnostic visit cannot override a different scheduled job.

Directed job-origin/follow-up, estimate change-order and refund cycles fail.
Traversal and customer/context grouping are iterative, avoiding recursive walks.
Additional crew and agreement-covered equipment JSON lists are parsed strictly as
bounded UUID arrays: no wrong JSON type, invalid UUID, duplicate, missing member,
foreign customer's equipment, or lead repeated as additional crew. Broader nested
business envelopes are intentionally not declared validated by these two lists.

`captureSaved(in:)` reads every registered entity from an unchanged saved context;
it rejects unsaved changes and incomplete relationships without saving, deleting,
renaming or repairing anything. `decodeDetached()` returns only new detached
objects after this relationship preflight. Neither path grants an authenticated
workspace lease or changes the existing `core-field-v1` source/transport/receipt
gate. The relationship graph itself does not activate a staff workspace.

## Corrected ordinary billing and file handoff

The review reproduced a live selection defect in `JobBillingDocumentLinks` and
`ServiceDocumentAttachment`: an estimate without a diagnostic visit could be
selected for another job under the same customer even after it was scheduled
elsewhere. Three regression assertions failed: the job resolver, receipt target
and attachment eligibility all accepted the wrong scheduled job. The shared
`EstimateJobLineage` rule now closes that path in the real resolver and attachment
eligibility, as well as the new relationship preflight. Existing customer,
provider identity, duplicate, document type, invoice precedence and original-file
ownership checks remain in place. Standalone files/proposals and both actual
diagnostic and scheduled visits remain supported. This changes no account,
provider record, stored link or historical attachment ownership.

## Preservation and remaining gates

A missing parent is unresolved, not proof that it was deleted. Existing raw owner
records and the previous received snapshot remain intact. Retired catalog/template
rows may remain referenced; if a parent was actually deleted, the full versioned
server history must provide its original scoped lineage before that historical
reference can be resolved. This candidate does not invent a parent, use a matching
display name, strip the link or silently drop the child to make validation pass.

This preflight does not establish tenant authority. The future server must bind
the complete dataset to the authenticated company, environment, original source
store and current membership/assignment. Full raw enum and nested JSON/financial
validation, role projection including nested cost/HR/financial filtering,
schema-separated immutable ledger migration, complete source reconciliation,
atomic isolated encrypted staff import/lease, durable field commands/conflicts,
file-byte delivery and signed independent-account CloudKit convergence remain
required. So do the remaining provider/vendor/payment/Handoff and full iPad/Mac
usability/accessibility requirements in the full business-suite goal.

## Qualification

Final local qualification and original-project copy-back pass. Retained evidence:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/Staff Relationship Graph.gfMXLf`.
`MacFocused1` preserves the initial test-fixture argument-order compilation error.
The immutable key/scope/error values now explicitly use nonisolated value semantics
instead of inheriting the app's MainActor default for their Hashable/Equatable
conformances. Actual model reads and graph building remain MainActor-isolated.
`EstimateReproduction1` is not qualifying evidence: the individual Swift Testing
selector ran zero tests despite xcodebuild's success status. The complete
`EstimateReproduction2` suite actually ran 15 tests, with the new wrong-job case
failing three assertions and the other 14 cases passing. Final qualification
must inspect actual executed test identities, not console success alone.

`MacFocused3` verifies 62 actual tests across all six requested suites; final
`MacFull1` verifies 1,744 actual cases without failures/skips. The new relationship
suite covers every classified FK, same-scope wrong originals, 512 change-order
links/cycle rejection, and a real SQLite saved-source read that cannot save or
replace incomplete data. All 72 final Tools tests and both workflow lint checks
pass. The workflow appends the new receipt journey to all prior 66 selections and
increases only iPad's job limit to 90 minutes. Terminal published predecessor
`40e82aa` has Backend/Mac/iPad-group-2 passes; GitHub explicitly canceled group 1
for exceeding one hour while tests were still progressing. See NATIVE_CI.md.

Unsigned Release builds and architecture checks pass for arm64 iOS and universal
arm64/x86_64 Mac Catalyst. SHA-256:

- iOS: `9caa2494d1b1f7bbb1f91fd792aea16376f70bf75479fcd6ee967a6d2ff2b41a`
- Mac: `a3919eb04455f05f264253e961a02482ff6e72717d4710cf08152d13f080be13`

Existing QBO document actor-isolation warnings and host linkd/optional Mac Metal
diagnostics are retained, not suppressed or claimed fixed. Backend code is
unchanged; no new full local backend run is claimed.

`IPadFull1` verifies 1,752 actual cases with zero failures/skips: 1,744 logic
cases and all eight requested UI journeys. These include wrong-job receipt
rejection/return to the original estimate, transaction type/ID consistency,
retained milestone invoice collection, invoice opening, simple Mail, schedule
deletion protection, estimate keyboard editing and staff invitation recovery
after relaunch. The fixture-only UI paths do not use a live provider or CloudKit.
Two final-source screenshots were inspected: the unresolved receipt target and
simple Inbox. Neither includes an account-email footer. The administrator receipt
screen still exposes manual QuickBooks ID controls and needs a broader usability
pass; these two frames are not proof of complete accessibility or suite polish.

`OriginalPreflight3.json` freezes 13 scoped paths and protects 355 unrelated
changes, 373 other matching sources and the original branch/HEAD/index.
Only workflow/Tools and documentation changes followed the first app-source
freeze; the exact app, logic-test and UI-test sources qualified above are unchanged.
`OriginalCopyBack1.json` verifies all 13 files are byte-equal, all 355 unrelated
changes are preserved and the original branch/HEAD/index are unchanged.
Publication and exact new-head hosted acceptance are recorded separately.

No live CloudKit/provider/customer/accounting/payment/supplier write, deployment,
signing/schema promotion, physical installation or main merge is included.
