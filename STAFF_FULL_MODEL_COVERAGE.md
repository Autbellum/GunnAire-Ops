# Complete persisted-model coverage for staff workspace preparation

Candidate, September 9, 2026. This extends the nine-model work recorded in
`STAFF_MODEL_SEMANTICS.md` to all 32 current SwiftData entities. It does not declare
full staff synchronization or the complete business-suite goal achieved.

## Implemented boundary

The closed `StaffWorkspaceModelCatalog` registers exactly one explicit codec per
actual model. It checks entity names, every persisted attribute, every owning and
inverse relationship, and explicit exclusions against `GunnAireModelSchema`.
An added/removed model or unclassified field fails coverage, rather than silently
disappearing from a full-domain snapshot. There are 561 explicitly named field
mappings, plus model IDs, inverse relationships and three excluded attributes.
The Tools test checks each literal mapping against its actual same-named key path.

New coverage:

| Group | Models |
| --- | --- |
| Workforce | AppUser, TechnicianAvailabilityBlock, TechnicianWorkShift, TechnicianTimeOffRequest, TechnicianAvailabilityEvent, TimeEntry |
| Operations | RecurringMaintenanceContract, ServiceRequest, ServiceCallActivity, ProjectMilestone, CustomerOperationalAlert, BusinessTask, BusinessTaskEvent |
| Field records | ServiceDocumentAttachment, CustomerCommunication, FieldFormTemplate, FieldFormResponse |
| Resources | Vendor, PurchaseOrder, InventoryMovement, FleetVehicle, FleetVehicleEvent, FieldExpenseClaim |

The original nine Customer/Location/Equipment/Technician/Item/Job/Invoice/Estimate/
Payment mappings remain included. Every scalar is copied explicitly after fresh
construction; constructor normalization, generated audit events, inferred dates,
current prices and default states cannot replace saved historical values.
Inverse collections rebuild from actual owning references. The batch preflights
all kinds, records, duplicate identities and owning references before allocating
the detached graph; input order does not determine the result. It never inserts
into, saves, updates, deletes or activates a caller's store. Per-model source reads
reject a context with unsaved changes.

## Security and compatibility

These are **owner-side persistence codecs**, not safe-to-distribute staff payloads.
They preserve private HR notes, purchase/labor costs, provider metadata and nested
financial history; explicit full server-side role projection remains mandatory.
Imported AppUser attributes are replica data, not business membership authority.
The existing production access policy still requires matching authenticated
backend membership. No AppUser row or successful decode grants a workspace lease.

`Customer.storedPaymentMethodsJSON` and `Payment.storedCardID` remain excluded as
charge-capable handles. `ServiceDocumentAttachment.localFilePath` is newly excluded:
an owner's sandbox path cannot identify accessible content on a staff device.
The detached copy receives an empty path. Authenticated, integrity-checked content
delivery must produce a new local file before the attachment can be used. All
document IDs, associations, MIME/size metadata and provider receipts are retained;
this checkpoint does not claim the file bytes were transferred.

The six-kind `core-field-v1` ledger, immutable historical operations, role-filtered
encrypted receipt, private CloudKit transport and staff gate are unchanged.
No backend wire version or CloudKit schema was relabeled or migrated. These codecs
must not be connected to distribution or staff activation until the remaining
domain, access, content, command and store-lifecycle gates below are implemented.

## Qualification

Final candidate qualification passes. Retained evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/Full Staff Model Coverage.PdShMz`.
`MacFocused1` retains the initial missing-`try` compile failure in a throwing
short-circuit expression; the implementation was corrected before the next run.
`MacFocused3` retains a test-helper default-argument actor-isolation compile error;
resolver allocation now occurs inside the main-actor helper, without isolation
suppression. Final `MacFocused4` verifies 16 actual cases across the existing
seven-case codec suite, five complete-model cases and four workflow-history cases.
`MacFull1` verifies 1,730 actual cases with zero failures/skips. The final review
strengthened every field's rejection test with finite, JSON-encodable wrong-type
probes (rather than relying only on JSONEncoder rejecting infinity). Only that
logic-test file changed, as the two frozen source manifests prove. Final
`MacFull2` and `IPadLogic2` each verify 1,730 actual cases with zero failures/skips.
`IPadFull1` verifies 1,736 cases on the identical app/UI source: all logic plus
Invoice opening, estimate keyboard editing, schedule deletion, simple shared Mail,
staff invitation relaunch recovery and administrator CloudKit-review return.
All 71 Tools tests
pass (`Tools1.log`), both unchanged workflows pass actionlint, and diff checks pass.
The initial Tools threshold guessed 600 fields; actual explicit mapping inventory
is 561 and now asserts that exact count, alongside authoritative schema coverage.

The schema sentinel test exercises present and explicit-null scalar values for
every kind. A separate real two-SQLite-store test writes the full graph, reads all
32 entities through a fresh context, reconstructs detached objects, transactionally
writes another store, rereads every record, and proves the source is unchanged.
Missing/extra fields, unsupported versions/kinds, duplicate identities, nonfinite
values, wrong model types and missing owning references reject the batch.
Scenario tests separately prove original agreement approval/cancellation/renewal
and invoice-event identity, purchased lines after catalog changes, form answers
after template changes, private HR reviews, original QBO time receipts, historical
task assignments, fleet events, original consent, absent delivery timestamps and
unchanged reimbursement audit/amount/reference. No business action is replayed.

Unsigned Release builds succeed for arm64 iOS (`DeviceRelease1`) and universal
Mac Catalyst (`MacRelease1`); the corrected input-first lipo checks verify arm64
and arm64/x86_64 respectively. SHA-256:

- iOS: `147f8df81fb6fcccae2c498c2562b421dcef46d2d8096f4cfac3aacc308da7cf`
- Mac: `052b7c3ac52f46fb82c9852640a4792c39bd22f9f6045227ac9eb71393a803e5`

The existing QBO document default-argument actor-isolation, optional Mac Metal
search-path and host linkd diagnostics were not suppressed or declared fixed.
Two final-app-source iPad frames were inspected: the simple Inbox and retained
billed schedule job/deletion explanation. Neither has an account-email footer.
They are targeted visual evidence, not full-suite accessibility qualification.
Backend code is unchanged; no new local full-backend test result is claimed.

Original-project `OriginalPreflight2.json` covers 12 paths, 352 unrelated changes
and 370 other matching tracked sources, preserving branch/HEAD/index.
`OriginalCopyBack1.json` verifies all 12 files are byte-equal after copy-back and
all 352 unrelated changes, the original branch/HEAD and index are preserved.
The qualified changes are retained in a local review-branch commit; publication
waits for the live predecessor's native CI to finish. The exact
published predecessor is `40e82aa`: Backend run `34346715118` passed both Python
jobs; Native run `34346715549` is still running. No push cancels that live run.

## Required next work, without narrowing the goal

- Validate every nested JSON business envelope and raw enum, historical link,
  tenant lineage, version and financial invariant. Scalar preservation is not
  semantic validity. The sentinel tests intentionally prove raw-value preservation,
  not valid business records. Historical snapshots may outlive their source
  catalog/template rows; lineage policy must distinguish history from active links.
- Define full role projections including nested cost/HR/financial redaction,
  signed membership and assignment authority; migrate the versioned server ledger
  without overwriting existing immutable `core-field-v1` operations.
- Connect complete source capture and reconciliation, atomic isolated encrypted
  staff-store import and lease activation, durable idempotent field commands,
  explicit conflict ownership and protection for unsynced edits.
- Deliver actual authorized media/document bytes with integrity and offline
  recovery. Validate independent-account signed CloudKit convergence on devices.
- Finish provider/vendor/payment/Handoff acceptance, remaining competitor-feature
  gaps and whole-suite iPad/Mac navigation/accessibility qualification. Native
  Tap to Pay entitlement/PSP and physical iPhone acceptance remain separate gates.

Migration review found that the current server's heads, records and operation
tables are not scoped by domain schema. Do not simply change `SCHEMA_VERSION` or
insert the 32-model fields into those six-kind rows. The next implementation must
separate the new schema's source revisions, immutable operations and projections,
retain old receipt/transport recovery, validate the full domain before projection,
and make the native receiver explicitly dispatch the exact validated schema. It
must distinguish a genuinely empty authorized dataset from missing model coverage.

No live provider writes, customer messages, payments, supplier orders, production
deployment, signing/schema promotion, physical installation or main merge are
part of this checkpoint.
