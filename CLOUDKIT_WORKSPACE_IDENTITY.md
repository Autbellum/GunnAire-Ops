# Company CloudKit workspace boundary — 2026-09-06

Status: server contract and native client contract implemented; **runtime storage
enforcement is still open**. This is not a claim that PR #18's company-isolation
finding is fixed. Nothing has been deployed, rebound, or migrated in production.

## Confirmed failure and scope

`OperationalDataContinuity.workspaceAccess` currently treats a nonempty local
store as sufficient for staff and bypasses the check for administrators.
`ContentView.refreshCompanyOperationalRecordState` only counts records. Neither
proves the records belong to the authenticated business.

There are additional paths outside that screen gate:

- `GunnAire_OpsApp.buildStartupState` attaches CloudKit and creates starter data
  before application authentication.
- `LoginView` reads and writes user/technician models before workspace validation.
- `GunnAireIntentStore` independently opens the same store for Shortcuts entities.
- ContentView starts upload retries, maintenance and payment polling on appearance.
- `CKAccountChanged` currently refreshes a notice, without invalidating data access.

The fix must cover those paths; adding a sidebar warning alone is insufficient.

## Implemented server contract (candidate 2026.09.06.20)

Each backend database receives a random, durable `companyID`. Database restarts,
additive migrations and full-database backups preserve it. Email domains, local
record counts, administrator status and QBO realms do not determine it. This is
one company per backend database, not a claim of shared-database multitenancy.

`GET /api/workspace` requires a current opaque Apple or Google application
session and returns the current approved user plus `workspace` containing
`companyID`, `containerID`, and `bindings`. Legacy shared API tokens and raw
provider identity tokens cannot authorize this contract.

`POST /api/workspace/bind` requires all of:

- A current administrator application session issued within ten minutes.
- The exact `expectedCompanyID` most recently read from this backend.
- `containerID = iCloud.com.gunnaire.businesssuite` and `environment` exactly
  `development` or `production`.
- A lowercase, 64-character SHA-256 `cloudAccountHash`.
- Explicit boolean `confirmCompanyDataOwnership: true` from reviewed onboarding.

The server generates a random `replicaID` for the first binding per container and
environment. That binding is immutable. Identical retries return the first
binding and approval time with no second audit; a different account hash returns
409. There is no automatic replacement or rebinding endpoint. The write
transaction rechecks session revocation, expiry, age and current administrator
role. Approval and audit commit together, or neither commits.

The hash is an administrator-approved device assertion, **not Apple-issued
identity attestation**. The native app must fetch the actual current CloudKit
record ID through `CKContainer.userRecordID()`, derive the scoped digest, and
validate local replica metadata as well. Merely possessing this response is not
proof of local data ownership.

HTTP outcomes: 200 for reads/replays, 201 for the first approval, 400 for malformed
or unconfirmed inputs, 401 for unauthenticated access, 403 for insufficient or
stale session authority, 409 for changed company/account bindings, and 503 for
missing identity or unavailable transactional storage. Responses contain no
session token, raw iCloud account identifier, or customer data.

The Swift client decodes these contracts, rejects ambiguous/malformed bindings,
separates Development and Production, and verifies approval response fields
against the submitted request. No current login path invokes approval implicitly.

## Required native integration (not yet implemented)

1. Identify the actual signed CloudKit environment and current iCloud record ID
   before attaching operational mirroring. Do not infer environment from QBO or
   accept a caller-selected company as authentication.
2. Persist a workspace marker with the operational replica, containing the exact
   company, replica, container, environment and scoped account digest. Validate
   every marker; conflicting markers fail closed. Data without a marker is
   unverified, even for administrators.
3. Provide explicit, recently authenticated administrator onboarding for a new
   or legacy store. Preserve the existing store and unsynced records. Review
   ownership before adopting it; never silently relabel a populated store.
4. Put the boundary before operational ModelContainer attachment, model-backed
   login writes, ContentView creation, Shortcuts queries, exports and background
   sync. A company/CloudKit account change must invalidate in-flight access and
   prevent uploading the old company's work with the new credentials.
5. Bind any offline authorization cache to the backend origin, company, exact
   staff session/role, replica, CloudKit account and environment. Define bounded
   validity, revocation recovery, and account-change handling; a cache hit alone
   cannot prove the currently selected iCloud account. Preserve saved field work
   even when identity cannot currently be verified.
6. Isolate company-specific caches, pending Handoff routes and provider work.
   Retire the record-count heuristic only after every entry path uses the real
   boundary. Role restrictions continue to apply inside an approved workspace.

## Verification and release acceptance

Current local verification: 87/87 backend tests, 37/37 release/tool tests, and
721/721 M5 13-inch iPad Simulator logic tests, all with zero failures. The three
new native contract tests passed first in isolation, followed by the entire
logic suite against that build. Mac Catalyst Debug builds successfully. The
simulator result is retained at
`/tmp/GunnAireQBORetryDerivedData/Logs/Test/Test-GunnAire Ops-2026.09.06_20-32-24--0400.xcresult`.
These tests use local fixtures, temporary databases and loopback HTTP; they do
not constitute signed CloudKit, offline-device or production acceptance.

Backend regression covers stable/restarted identity, distinct databases, every
staff role, Apple/Google sessions, legacy-token denial, exact metadata and
ownership confirmation, conflicting/concurrent approvals, immutable replays,
fresh-session enforcement, revocation between authorization and commit, audit
rollback, and missing-identity recovery without silently reassigning a replica.
Native contract tests cover Codable compatibility, environment separation,
missing/duplicate/foreign/malformed bindings, and explicit ownership encoding.

Remaining runtime acceptance must demonstrate: populated foreign store denied to
staff **and** admin; unbound legacy store preserved; correct empty and populated
replicas admitted only after proof; account/backend switches locked before data
or uploads escape; no Shortcut/entity/sheet/background bypass; safe offline work
on an approved device; pending unsynced work retained on revocation; and verified
CloudKit convergence on the physical company iPad and Mac.

Before deploying this additive migration, verify an off-host database backup and
restore test. Preserve both new tables during code rollback. A missing company
identity with an existing approved binding returns an error and startup refuses
to generate a replacement identity. Restore the original database; do not
manually delete binding rows to evade that safety check.

Apple references:

- [Fetching the current CloudKit user record](https://developer.apple.com/documentation/cloudkit/ckcontainer/fetchuserrecordid(completionhandler:))
- [CloudKit synchronization and account configuration](https://developer.apple.com/documentation/technotes/tn3164-debugging-the-synchronization-of-nspersistentcloudkitcontainer)

Apple documents that private-database replication uses the same iCloud account
across devices, whereas CloudKit sharing supports separate owner/participant
accounts. Supporting employees' independent personal iCloud accounts remains a
separate architecture requirement; this contract does not implement sharing.
