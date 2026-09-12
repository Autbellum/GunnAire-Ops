# Staff CloudKit data delivery — September 9, 2026

The data-authority checkpoint below precedes the new
[encrypted CloudKit transport](STAFF_CLOUDKIT_TRANSPORT.md). That later stage adds
upload/download and durable encrypted staging, but not source scheduling, a staff
operational store, full business schemas or field-edit reconciliation.

## Current checkpoint and remaining full-suite requirement

Backend `2026.09.09.48` adds an encrypted operational source ledger and immutable,
role-filtered payload preparation. Native `StaffReplicaCoreSource` captures saved
owner facts using explicit fields, with a live owner-account/workspace check before
its callable capture entry point. It is not yet scheduled from the app lifecycle.

This is the data-authority and serialization stage, **not completed staff data
synchronization**. The app still does not mount a staff operational store. All
projection receipts say `operationalWorkspaceReady: false` and require independent
live Apple proof. No CloudKit upload/download, background export journal, staff
import/store, field command reconciliation or new navigation is activated here.
The previously implemented explicit private invitation/acceptance UI is unchanged.

The versioned `core-field-v1` schema declares exactly six record kinds: customer,
service location, equipment, technician identity, core job details and core
pricebook facts. `completeForSchema` means only that enumerated schema, not all
properties of the app's SwiftData models or a full business workspace. Invoice and
estimate snapshots/bundles/tax/approvals, time, diagnostic readings/checklists,
service history/media/forms, agreements, tasks, expenses, inventory/fleet and the
remaining operational/financial domains still require explicit serializers and
their authorization rules. Existing Google/QBO publication services are unchanged;
this ledger never grants accounting or payment authority.

## Source ledger and original-operation recovery

`POST /api/workspace/replica-records` accepts an active Admin application session,
the exact company/environment, `schema`, stable `operationID`, `expectedSequence`
and at most 100 changes in a bounded 2 MiB body. Each change includes its original
kind/UUID, `expectedRevision`, `upsert`/`delete`/`restore` action and explicit fields.
Unknown kinds/fields, duplicate objects/records, noncanonical IDs, invalid scalar
types and nonfinite values are rejected. A whole batch commits transactionally
with its receipt and audit record. Conflict, encryption or audit failure commits
nothing; local work must remain for review.

Every row is encrypted with the existing backend payload-encryption key. Encrypted
content binds company, signed environment, immutable replica, kind, stable ID,
revision and deletion state. Copied/wrong-key/corrupt ciphertext cannot be exported
or overwritten as if it were an empty record. Idempotent replay checks the exact
actor/scope/request hash and returns the original applied sequence, separately from
the current sequence. No late retry reapplies a batch. Source reads are also Admin
only and recheck the actual session and business binding inside the transaction.

`GET /api/workspace/replica-records?companyID=…&environment=…` reads 100 ordered
records with an explicit cursor. Continuation requires the exact `sequence` and
`after` cursor; a changed source requires restarting the read without discarding
pending edits. Deletions are retained with their prior encrypted data for owner
recovery. They are never inferred from an incomplete fetch or a missing local
CloudKit relationship. Reviving a deleted ID requires explicit `restore` against
its current revision. Source record IDs/query cursors are redacted from HTTP logs.

Routine source publication uses a current Admin session, not repeated ten-minute
invitation approval. The future native publisher must additionally verify that it
is the actual bound CloudKit owner, record durable intent before POST, and compare
local edits against its last acknowledged baseline. It must not treat a fresh
server revision as permission to overwrite a newer remote edit with stale local
values. SwiftData history/bootstrap/deletion capture and conflict resolution are
still required; this source endpoint is not an automatic mirror.

## Membership-filtered snapshot contract

`POST /api/workspace/staff-shares/{membershipID}/projections` takes a stable
`operationID`, exact company/environment, `expectedSequence` and
`expectedShareRevision`. Only current Admin sessions can prepare payloads. The
original share must be accepted and eligible with unchanged active member and
approver revisions, binding and policy. A repeated operation returns only its
original projection receipt and current freshness/authorization verdicts.

Filtering occurs before any payload bytes are returned:

- Field Technician: exactly one matching active technician profile, assigned
  lead/crew jobs, their customers, relevant properties/equipment, assigned crew
  contacts and approved/archived pricebook items plus that worker's own draft
  items. Other customers, other properties of the same customer, unrelated staff,
  other workers' draft items and purchasing costs are not exported. An absent or
  ambiguous technician mapping is review/pending, not a successful empty work list.
- Dispatcher: core operational data without purchasing costs or financial/payroll
  administration. Admin receives authorized core facts, never raw provider bodies,
  stored payment methods or worker labor cost.
- Standard and Accounting: no implicit grant from this core-field schema. Their
  self/task and financial-domain schemas remain required; an empty core payload
  does not mean those business roles are ready to use the complete app.

Missing related records block preparation until sync completes. Wrong-customer or
wrong-property links require review. Cross-job navigation IDs cannot widen the
downloaded job set. A legacy job can retain the property of its exact equipment
when the job itself has no property ID; no unrelated location is inferred.

Each payload identifies schema/coverage, company/environment/replica, membership,
member revision/policy, original operation, source sequence and authorization
sequence. The encrypted original bytes, SHA-256, byte count and record count are
retained. Full schema snapshots express the current authorized record set; removing
an assignment removes those records from the next snapshot. An importer must apply
that entire validated set atomically, preserving pending field commands separately.

`GET /api/workspace/staff-shares/{membershipID}/projections/{operationID}` returns
metadata/authority to that member or an Admin, not a business-data download.
Appending `/payload` permits an Admin to obtain the exact base64-encoded payload
for the owner CloudKit publisher. Staff must receive the payload through the
verified private CloudKit share, not bypass CloudKit through this endpoint.

Data freshness and permission freshness are deliberately separate. Ordinary
content edits advance `sourceSequence` without continually cancelling an otherwise
authorized in-flight snapshot. `isCurrent` stays false for old data. Assignment,
identity, visibility, relationship, insertion/deletion/restore and pricebook-review
changes advance a separate monotonically increasing authorization sequence. Such
changes block old payload publication; assigning away and back cannot reauthorize
an older export. Member/approver role changes and business revocation independently
block all reads. A native importer must never use `currentSequence` as the applied
checkpoint for older bytes or overwrite a newer local imported snapshot.

## Storage, rollout and limits

SQLite migrations are additive. They retain source records, operation receipts and
encrypted snapshots. Earlier payloads without authorization-sequence evidence stay
retained but cannot acquire authority merely through migration; prepare a new
snapshot against the current source. Backups must include the whole database and
the existing payload-encryption key; neither database nor key alone is sufficient.

This version bounds a source record to 64 KiB, a batch to 100 records/2 MiB,
source recovery pages to 100 records, snapshot scans to 20,000 source records and
64 MiB of ciphertext, and a final snapshot to 16 MiB. Limits fail with an explicit
packaging/review error; there is no truncation. Incremental indexed selection,
chunk manifests, large-history packaging, retention and deletion cleanup must be
implemented before claiming large-business readiness. No retained source or
snapshot is silently deleted by this checkpoint.

## Verification and next delivery steps

Evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/Staff Data Authority.IWcHKL`.
Final-source qualification passes all 838 backend tests, including 38 new replica
cases, and all 69 Tools tests. Mac passes 1,629 logic cases; M5/iOS 26.2 iPad passes
1,633 actual cases (1,629 logic plus four existing invoice/mail/onboarding journeys),
with zero failures/skips and exact selected-test execution verification. Both Mac
and iPad six-kind JSON attachments from the real native capture pass the Python
server-contract verifier. Three iPad screenshots were visually inspected and have
no account-email footer. Unsigned universal arm64/x86_64 Mac Release and arm64 iOS
Release builds succeed; their actual binary architectures were verified. No new
source-specific warnings appeared; existing document-concurrency/optional Metal
warnings are not suppressed.

Original preflight freezes 12 scoped files and verifies 335 other tracked source
files match, while preserving 305 unrelated original changes and its existing
branch, HEAD and staged index. Final copy-back verifies all 12 scoped files match,
preserving all 305 unrelated changes and the original branch/HEAD/index. The previous
published head `4a865d9` has passed Backend CI; its native run remains live. This
new source requires its own hosted checks after publication, and local fixtures
are not signed cross-account/provider acceptance.
The first backend run retained one failure: wrong-customer links were reported as
pending due to traversal order. The corrected graph check distinguishes a missing
parent from an explicitly inconsistent property/customer relationship.

Next required work is durable owner source-change capture/reconciliation, the
exact original CloudKit upload/recovery bridge, accepted staff download with fresh
authorization checks, an encrypted independently registered import store, complete
role-specific business schemas, and durable field commands whose receipts converge
through the owner store and QBO boundaries. Signed independent-account tests must
prove account changes, offline work, revocation, pagination, restore, conflicts,
relaunch and iPad/Mac/iPhone convergence. The full business-suite goal remains open.

No deployment, main merge, signing/portal/schema promotion, physical install, live
CloudKit/customer/accounting/payment write or vendor order is part of this stage.
