# Staff discriminator validation before reconstruction

Candidate, September 9, 2026. This advances the complete 32-model staff work;
it does not claim nested business envelopes or independent-account CloudKit
operation complete.

## Implemented behavior

`StaffWorkspaceDiscriminators` classifies every current persisted `Raw` field
across all 32 schema entities, plus the job's enum-typed type/status, estimate
proposal option and attachment Drive state. Coverage checks the actual model
catalog/schema; adding an unclassified raw field or model fails the boundary.
It uses the existing domain enum initializers, not copied display-name lists,
case conversion, guessed defaults or the models' permissive computed getters.

The full `StaffWorkspaceRelationshipGraph.validate` path now runs these checks
before it can return a graph for detached reconstruction. `captureSaved(in:)`
uses the same path. Unknown weekday, dispatch urgency, review/approval/tax type,
role, vehicle safety status, work type, catalog type and other raw codes reject
that attempted graph. The existing lossless owner codecs remain unchanged so
the exact rejected values remain available for review and future migration.

Both persisted newline sets are validated without trimming, sorting, dropping
unknown entries or deduplicating: fleet failed-inspection items and original
QuickBooks attachment receipt keys. The latter preserve all six supported
entity types and the entire original ID, including colons within the ID. A
recognized receipt is not an upload instruction or proof of current accounting
state. Null and explicitly empty historical sets remain distinct values.

Optional-null fields stay null; required-null fields are still rejected by
their original scalar codec. The explicit catalog `Unknown` marker remains a
recognized needs-review state, not permission to sell or publish that item.
An imported `admin` role remains data, never a backend membership grant.

Errors contain only the model kind/record UUID and field name, not the saved
value or customer/provider contents. Validation cannot save, repair, delete,
issue a new operation, publish accounting data or change a source context.
The per-kind rule table is reused across the graph rather than rebuilding all
561 field mappings for each record.

## Evidence and qualification

Evidence root:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/Staff Discriminators.3fSCzM`.

The regression suite reproduces the existing getter hazard independently of
the new gate: a saved weekday of 0 is preserved by the lossless codec, but the
model's computed weekday returns Monday; an unknown dispatch urgency returns
Normal. Both now reject through the full graph boundary instead of becoming
apparently valid operational values. Supported core scheduling, role, catalog
and tax choices, every raw field, optional/null behavior, malformed/duplicate receipt and safety-set
members, unchanged source values and replica-role non-authority are exercised.
A real SQLite source test retains a previously validated graph, writes an
unknown code, rejects a fresh capture and proves that the original saved value
and prior graph remain intact without a hidden save or replacement.

Initial discriminator qualification verifies `MacFocused1.xcresult` (26 actual
cases across the three required suites) and `MacFull1.xcresult` (1,763 actual
cases across the complete logic target), with zero failures/skips. Unsigned
universal Mac and arm64 iOS Release builds and architecture checks passed; all
74 Tools tests and both workflow lint checks passed.

`IPadFull1.xcresult` contains 1,769 passes and one failure, with zero skips. All
1,763 logic cases and six of seven UI journeys passed. The inventory journey
visibly retained `6` after hardware entry of `6.5`; its original recording is
retained under `InventoryFailure1`. This is not a passing broad iPad result.
The quantity editor is being corrected and requalified before copy-back; see
`IPAD_EDITOR_RECOVERY.md`. Initial release hashes are predecessor evidence, not
evidence for that subsequent source change. No complete application or staff
CloudKit acceptance is inferred from the logic checks.

Current combined source: `MacFull3.xcresult` verifies 1,768 actual cases for the
complete logic target, zero failures/skips. `MacFull3Release.log` and
`DeviceRelease2.log` pass unsigned Release builds plus Mac arm64/x86_64 and iOS
arm64 architecture checks. Mac binary SHA-256 is
`5a00c5f92e452015bdb76a02566876e21b8f62d63db932c3651f9504bad9c725`;
iOS binary SHA-256 is
`7de189ff0e73322981a76b3488acccb0d80e85cb911bfd849b000d4018ac620a`.
All 74 Tools tests and both workflow lint checks pass again. `IPadFull2.xcresult`
verifies 1,779 actual cases, zero failures/skips: the complete logic target plus
all 11 selected UI journeys (all 12 selectors verified). Those journeys include
both staff request/admin recovery paths, unverified-role restrictions, the
invoice workspace, simple Inbox, inventory quantity validation/save/cancel,
taxable catalog creation, pricebook review, and all three bundle editors.
The saved-fractional inventory and original-estimate confirmation frames were
visually inspected without account-email footers. This does not cover light
mode, extreme Dynamic Type, VoiceOver or complete Mac UI.

`QuantityFreshProcesses1` completed successfully on September 9 at 16:50 UTC.
Its authoritative tree contains three Passed repetitions with independent app
relaunches, and its exported manifest has the required saved-fractional attachment
for each repetition (1, 2 and 3). All three final frames were visually inspected:
quantity `6.5`, original `2026-09-08` date, full `125.375` price, persistent labels
and no account-email footer. The expanded create/edit invalid-input checks and
keyboard-active save executed in all repetitions. Durations were 116.123,
3,997.205 and 114.029 seconds. The second launch's repeated XCTest animation
completion waits remain retained diagnostic evidence, not proof of normal
interaction latency; no live process was cancelled or restarted. All repetitions
also retain an unattributed non-finite-frame runtime warning.

This exact candidate is qualified for scoped copy-back and review-branch
publication. `OriginalPreflight2.json` protects all 11 paths, 364 unrelated
changes, 378 other matching tracked sources and the original branch/HEAD/index.
The existing PR's published predecessor `f8cfc92` has successful backend/native
runs; those hosted results do not cover this newer source. No release promotion,
provider mutation or full application acceptance follows from this checkpoint.

## Remaining full-goal requirements

This boundary deliberately does not label arbitrary status strings or nested
JSON as understood. The complete nested envelopes (including structured data
embedded in notes), historical approvals/billing/inventory/form/time/expense
semantics and financial invariants still require explicit versioned validation.
Full authenticated role projections with nested HR/cost/financial privacy,
schema-separated immutable server ledger migration, source reconciliation,
atomic isolated encrypted staff-store import and lease activation, durable
field commands/conflicts and integrity-checked file-byte delivery remain needed.

The six-kind `core-field-v1` protocol, transport, receipt and staff gate are
unchanged. No incomplete workspace is activated, raw owner record is distributed,
or existing ledger overwritten. Signed independent-account CloudKit convergence,
provider/vendor/payment/Handoff/device acceptance and complete iPad/Mac usability
and accessibility also remain required. The full business-suite goal stays active.
