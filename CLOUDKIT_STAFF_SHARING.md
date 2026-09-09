# Independent staff CloudKit sharing — September 9, 2026

Status: **authorization registry and native invitation-validation foundation**.
This is not yet an end-to-end staff-sharing implementation or a release gate pass.
Backend candidate `2026.09.09.46` adds the registry. The existing private SwiftData
store gate, signing settings, entitlements, schema and startup behavior are unchanged.
No live iCloud records, users, invitations, deployments or accounting data changed.

## Framework decision and intended complete data path

Current Xcode 26.6 SDK and Apple's documentation expose SwiftData CloudKit
configuration choices `automatic`, `none` and `private`; no shared-database choice
is exposed. CloudKit sharing instead exposes a hierarchy in the owner's private
database and the participant's shared database. Sharing the existing SwiftData
internal zone, re-labeling a populated local store, or allowing a staff account
to bypass the approved private-account binding is not a valid migration.

The implementation direction preserves the company-owned private SwiftData store
and adds a **separate CloudKit hierarchy per staff membership**. A hierarchy has
a dedicated custom zone, an explicit root, private invitations and read-only
participants. Staff using different iCloud accounts will use a separate local
projection store; they will not mount the legacy private business store.

CloudKit remains the cross-account delivery and durable replica layer, not an
optional substitute for it. Field changes require a durable, encrypted local
operation journal and current backend authorization before being reconciled into
the company data and republished through CloudKit. The existing shared QBO
publication services retain accounting authority. A participant must not gain
write access to a shared company projection merely to create an invoice item.

The complete path still to connect is:

1. Staff signs in with an approved business session and reads their actual,
   signed-environment CloudKit account. Enrollment records only a scoped hash.
2. Administrator reviews that exact staff identity, account and business role.
   Server reserves a unique zone/root/share before any Apple write.
3. The approved owner device verifies its actual CloudKit account and creates or
   recovers that exact hierarchy. Only the exact reviewed participant is invited,
   privately and read-only. Never offer public or writable share options.
4. Staff verifies live Apple metadata against the original backend plan before
   accepting, then verifies the fetched root and accepted permission. A durable
   acceptance journal handles lost responses without creating another share.
5. The owner exports only the role-scoped projection; staff imports it into a
   separately registered store. Both sides persist change tokens only with the
   corresponding durable record changes. Stable IDs, tombstones, ordering,
   pagination and change-token expiry must be handled without silent replacement.
6. Staff jobs, notes, equipment readings, media, time and invoice changes enter
   durable commands. Backend checks identity, current assignment, role and source
   revision; conflicts needing human review stay visible. Receipts converge back
   through the company store and CloudKit without duplicate QBO publication.

The registry and native proof code below implement inputs to steps 1–4. The
onboarding UI, Apple save/accept/revoke operations, durable journals, exporter,
importer, separate store lifecycle and command reconciliation are **not wired yet**.
Nothing in this checkpoint grants a staff device operational-store access.

For the next transport stage, Apple's current `CKSyncEngine` supports distinct
private/shared database instances, persisted opaque engine state, scoped batches,
explicit fetch/send and account-change events. It does not resolve application
conflicts or guarantee immediate sync. The planned engine must initialize only
after company/account proof, constrain fetch/send to approved staff zones, and
retain its state with durable local changes. Automatic retries must not be
treated as authorization or as proof of successful delivery; cancellation,
revocation during an in-flight operation, and original-operation recovery remain
explicit implementation and signed-device tests.

## Role-scoped projection requirements

These policy identifiers are versioned authorization boundaries, not completed
serializers. Each serializer must allowlist fields and enforce current backend
assignment/role before export, not merely filter a shared UI after downloading.

| Business role | Reserved projection policy | Required scope |
|---|---|---|
| Admin | `admin-operations-v1` | Authorized business operations; never credentials or payment secrets |
| Dispatcher | `dispatch-operations-v1` | Dispatch, service history and communications needed for scheduling; no payroll or accounting administration |
| Field Technician | `field-assigned-jobs-v1` | Assigned jobs, relevant customer/equipment history, permitted pricebook and invoice work, own time/media; no other staff payroll or unrelated customer records |
| Accounting | `accounting-operations-v1` | Authorized invoices, reconciliation, expenses and approved time; no integration secrets |
| Standard | `standard-self-v1` | Explicit self/task access; no implicit full-company read permission |

Role-specific invoice/estimate item creation must continue to use shared catalog
and billing authorization. A CloudKit permission is never permission to mutate
QuickBooks, send email, approve time or collect a payment.

## Implemented backend contract

All routes require a current opaque Apple/Google application session. Legacy API
tokens and provider identity tokens cannot authorize them. The service rechecks
current session, expiry, role and active status inside each database transaction.
One backend database remains one durable business; this does not introduce
cross-business switching or shared-database multitenancy.

- `POST /api/workspace/staff-shares`: exact `companyID`, signed `environment`,
  stable `operationID`, `participantAccountHash`. Member email and role come only
  from the authenticated server user. An existing approved owner binding is
  required. The owner account uses the existing company-device onboarding path.
- `GET /api/workspace/staff-shares?companyID=…&environment=…`: staff sees only
  their own history; Admin sees company history. Fifty records per cursor page,
  explicit `nextCursor`, no silently truncated list. Single-record reads use
  `/{id}` with the same exact company/environment query.
- `POST /api/workspace/staff-shares/{id}/{action}`: exact scope, new stable
  `operationID`, `expectedRevision`, and the action-specific boolean confirmation.
  Actions are `approve`, `invite`, `accept`, `revoke`, `confirm-cleanup`.
  Acceptance also requires the original `participantAccountHash` and member.

Transitions are requested → approved → invited → accepted, with explicit terminal
revocation from any nonterminal state. Admin approval/invitation/cleanup requires
authentication within ten minutes. A participant can revoke their own business
access; changing another person's access requires a fresh administrator session.
The exact confirmation fields are defined by `StaffShares.change`; they are not
generic "confirmed" flags and do not attest that Apple performed an operation.

The row reserves immutable company/environment/owner replica, participant hash,
member role/revision, policy, random zone and share IDs, and root `workspace`.
Member and approver revisions include the server user's update timestamp. A
demote/reactivate or demote/restore cycle cannot silently restore an old grant.
Changes require a new reviewed membership and zone, not a broadened old share.

Writes use a transaction, compare-and-swap revision and operation journal. Exact
retries return **current** original state; a late approval retry never resurrects
a revoked share. Reusing an operation for another actor/action/payload fails.
Enrollment and audit, or transition/operation/audit, commit together or roll back
together. Concurrent enrollment/approval tests exercise these guarantees.

`businessAccessEligible` requires accepted state plus current member and approver
authority. Every response still has `localCloudKitProofRequired: true`.
`reviewRequired` and `cloudKitRevocationRequired` expose changed roles or cleanup.
The registry contains no share URL, raw iCloud record identity, bearer token,
customer data or accounting payload. Sharing paths/queries are redacted from
HTTP logs. Error responses do not expose another staff member's request.

## Implemented native checks

`CloudKitStaffSharePlan` decodes and validates the backend contract against the
original immutable workspace binding. It rejects unknown policy/role, foreign
company/environment/replica, owner-account substitution, malformed IDs/hashes,
invalid timestamps/states and unsafe eligibility flags. Successor checks pin
the original membership, account, role, zone and share and reject regressions.

`CloudKitStaffShareEvidence` reads actual `CKShare.Metadata` in memory. Checks
cover container, exact root/share IDs and owner-namespaced zone, owner identity
and share-owner agreement, actual participant account and signed environment,
current business member/role, private-user role, read-only permission and
pending versus accepted status. Public, writable, removed, unknown, owner or
CloudKit-administrator participants are rejected. No evidence is serialized as
a durable authorization token; it cannot unlock the existing private store.

`CloudKitStaffShareRecords.ownerDraft` constructs an empty isolated root and
private share for an approved owner plan. It does not access `CKContainer`, save,
send or accept anything. The root allowlists only protocol, company, replica,
membership, member-revision and projection-policy fields. Root verification
rejects extra payload fields. This deliberately does not export business data
before the projection serializers and lifecycle controls are implemented.

## Revocation, privacy and release gates

Business revocation is not Apple permission revocation. An owner must remove the
CloudKit participant/share and verify the original result before confirming
cleanup. An approved request may already have created an Apple share despite a
lost reply; revoking it therefore requires cleanup even before `invited` state.
Role changes invalidate business eligibility immediately on a fresh server read
and flag CloudKit cleanup. Already downloaded information cannot be remotely
"unread" or instantly erased offline; lease duration and retention/device-loss
policies require explicit acceptance. The exporter must stop publishing to an
ineligible membership even if Apple permission cleanup is still outstanding.

Before enabling the native path: implement all six data-flow stages, exact
role-field allowlists and conflict ownership; exercise revocation with pending
commands/media; verify restore and lost-Keychain recovery without data deletion;
and qualify two independent signed iCloud accounts plus the existing owner iPad
and Mac. Verify Development/Production schema, encryption, scale/zone limits,
change-token expiry, offline cold launch, push recovery and actual convergence.
Signing, schema promotion, production deployment and live invitations remain
separate authorized release steps. Preserve both new registry tables and the
original company/binding during backup and rollback; startup refuses to invent
a new company ID over retained staff-share history.

## Verification

All 27 focused backend sharing tests and all 793 backend tests pass locally.
The complete Mac logic suite passes all 1,600 cases. The 13-inch M5 iPad Simulator
(iOS 26.2) passes all 1,602 cases: 1,600 logic plus the original simple-Mail and
offline invoice/estimate navigation journeys. Nine new native sharing tests pass
on both platforms. The authoritative result trees verify both complete logic
targets, the sharing suite, and the two requested UI methods, with no failures or
skips. All three final UI screenshots are visually inspected: readable original
Mail/invoice/estimate presentation and no account-email footer. This is not a
full accessibility, visual, or signed-device acceptance claim.

All 64 Tools tests and both unchanged GitHub workflows pass validation. Unsigned
Release builds succeed for universal Mac Catalyst (arm64/x86_64 verified) and
generic iOS device (arm64 verified). Existing document-concurrency and optional
Mac Metal search-path warnings remain. No warnings were suppressed. First-pass
fixture issues (a helper argument swallowing a malicious role field, wrong log
stream capture, and missing optional-field initializer arguments) were corrected;
no production permission check or test assertion was weakened.

Release executable SHA-256:

- Mac: `3fc4e864d6d46b09ded98f431ebfe749e5222dad6ccab03bef406003ace6b620`
- iOS: `6d2e553bc706bce5834be24bde40a407ed20752a9600ebdac1a0a9b52f88c02c`

Original-project preflight records seven scoped paths, 293 unrelated changed
paths, 324 other identical tracked sources, and the original branch/HEAD/index.
Final scoped copy-back verifies all seven files are identical, preserving the
original branch, HEAD, index and all 293 unrelated changed paths. Evidence directory:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/CloudKit Staff.DNjPoM`.
These tests do not constitute signed cross-account CloudKit acceptance.

At predecessor `bf204bf`, hosted backend and Mac native checks passed; both iPad
jobs were still running at 01:59 Eastern. Publication of this candidate requires
fresh exact-head hosted qualification. The workflow already selects the complete
logic target; no selectors or permissions were reduced or changed here.

Primary sources verified in Safari and the installed Apple SDK on September 9:

- [SwiftData CloudKit database configuration](https://developer.apple.com/documentation/swiftdata/modelconfiguration/cloudkitdatabase-swift.struct)
- [Sharing CloudKit data with other iCloud users](https://developer.apple.com/documentation/cloudkit/sharing-cloudkit-data-with-other-icloud-users)
- [CKShare and participant permission boundaries](https://developer.apple.com/documentation/cloudkit/ckshare)
- [CloudKit sharing metadata](https://developer.apple.com/documentation/cloudkit/ckshare/metadata)
- [CloudKit sync engine and app-owned persistence](https://developer.apple.com/documentation/cloudkit/cksyncengine)

Apple's sample enables public read/write sharing for its demonstration. That
setting is not adopted for this business architecture.
