# Lossless staff-workspace model semantics

September 9 extension: `STAFF_FULL_MODEL_COVERAGE.md` records the added remaining
23 codecs and closed 32-entity catalog. The nine-model qualification below is the
prior baseline, not the current full-model qualification. Full staff role
projection, domain validation, isolated activation and command reconciliation
remain required; neither checkpoint unlocks an incomplete staff workspace.

Candidate, September 9, 2026. These are explicit owner-side model codecs, not a
staff access grant, server projection, or operational store activation. They are
not wired into the existing `core-field-v1` ledger or encrypted receipt pipeline.
That compatibility boundary remains unchanged until the full versioned domain
contract and role projection exist.

## Implemented

Nine persisted models have a complete attribute/relationship disposition:
Customer, CustomerServiceLocation, CustomerEquipment, Technician, Item,
ServiceCall, Invoice, Estimate and Payment. Values use explicit typed key paths,
not model reflection, KVC, runtime property dumps or initializer defaults.
Every declared optional field is present as its original value or explicit null.
Unknown/missing fields, wrong scalar types, unsupported versions, nonfinite or
out-of-bound values and duplicate record identities fail validation.

Actual relationship references resolve only against fresh detached objects of
the expected model type. Required parents are checked before constructing a
child, so a missing technician cannot mutate an already reconstructed customer's
inverse collection. Existing owner/staff ModelContext objects cannot be reused.
Inverse relationships are reconstructed from owning child records, not serialized
as competing lists. Full-domain graph and lineage validation is still required.

The mappings retain distinct lead/additional crew, visit equipment versus current
equipment, original service readings/checklists, consent, dates, signatures,
approval identity, exact sold catalog JSON, taxes, balances, partial-payment
amounts, and original provider/accounting receipt IDs. They do not recompute sold
prices, interpret a receipt as newly paid, or call any provider. Stored customer
payment-method handles and charge-capable stored card IDs are explicitly excluded.

These are **owner records**, not role-safe staff payloads. Purchase/labor costs,
provider metadata and nested catalog costs require explicit server-side role
projection before distribution. Stored JSON attributes are preserved byte-for-byte
as strings; the codec does not validate their internal business semantics. Scalar
UUID links also still need full graph/tenant checks. No imported AppUser row may
replace server membership authority.

## Verification and remaining scope

`StaffWorkspaceModelCodecTests` checks each mapping against SwiftData's public
32-model schema, every attribute and owning/inverse relationship disposition for
these nine models, exact encoded round trips, missing/unknown/type/version
rejection, parent/identity failures, and excluded payment handles. A real
two-SQLite-store test saves a source graph, reads it in a new context, reconstructs
fresh objects, saves them transactionally into another store, and rereads exact
job/invoice/payment records without changing the original source.
`Tools/test_staff_workspace_model_contract.py` independently checks that every
declared field name targets the same-named Swift property.

Qualification evidence is in
`/Users/gunnaire/Downloads/GunnAire Ops Releases/Staff Model Semantics.265WOl`.
`MacFocused1` verifies all seven codec tests. Final `MacFull2` verifies 1,721
actual logic cases; `IPadFull1` verifies 1,729 actual cases: the complete logic
target plus eight UI journeys for schedule deletion, invoice opening, simple
shared Mail, all three bundle editors, and both staff CloudKit setup/recovery
paths. All pass with zero failures/skips, using the exact execution verifier.
The destination is the 13-inch M5/iOS 26.2 simulator
`147D4CB6-85CC-4B17-BD35-8684E60E672D`; Mac tests use arm64 Mac Catalyst.

All 71 Tools tests pass in `Tools2.log`, both unchanged workflows pass actionlint,
and `git diff --check` passes. Backend code is unchanged; its preceding 852-test
pass remains retained in `Staff Receipt.xPKL2I/BackendFull1.log` and was not rerun
for this native-only checkpoint. Four final-source screenshots were inspected:
retained billed schedule job, simple Inbox, and edited/saved original estimate.
No account-email footer is present.

Unsigned Release succeeds for arm64 iOS (`DeviceRelease1`) and universal Mac
(`MacRelease1`); lipo verifies the required architectures. SHA-256:

- iOS: `d47e4f8cb427ace093173514ffa43187dfa7e3c49c9725bdf3381c4fabe5925f`
- Mac: `5162c8e82bcdf2806a436d4f88bb701896a6ddbd77495fba92d4bc1efd82d1cd`

Existing QuickBooks document actor-isolation and optional Mac Metal search-path
warnings remain; they are not suppressed. Original preflight freezes 14 paths,
covers 342 unrelated changes and 361 other matching sources, and preserves the
original branch/HEAD/index. Copy-back verification and publication are recorded
separately; fresh exact-head hosted checks remain required.

The remaining 23 models, role-filtered full-domain wire format, versioned server
migration, nested financial validation, cross-record lineage, atomic isolated
staff-store activation/lease, durable field commands and conflict ownership,
media/file content delivery, and signed independent-account convergence remain
required. This checkpoint must not open a partial/read-only workspace as a
substitute for the requested full staff application.

Apple's [ModelContext documentation](https://developer.apple.com/documentation/swiftdata/modelcontext)
was read in Safari on September 9; public schema/relationship/model-context API
availability was also checked in the installed Xcode 26.6 SDK. No private API,
CloudKit schema/signing promotion, production deployment, live provider writes,
physical installation or main merge is included.
