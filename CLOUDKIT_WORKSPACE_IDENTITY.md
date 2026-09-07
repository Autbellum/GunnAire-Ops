# Company CloudKit workspace boundary — 2026-09-06

Status: server contract, native startup/store gate, explicit onboarding,
Shortcuts gate, backend-request checks and bounded offline lease implemented.
Direct-provider request checks are now implemented and verified separately in
[PROVIDER_WORKSPACE_LIFECYCLE.md](PROVIDER_WORKSPACE_LIFECYCLE.md); the remaining
higher-level retained-context and payment-recovery boundaries are explicit there.
**End-to-end company isolation and signed-device acceptance remain open.**
Nothing has been deployed, rebound, or migrated in production. Deploy and verify
backend `2026.09.06.20` before distributing this native candidate; older backends
do not implement the required workspace proof and intentionally cannot unlock it.

## Confirmed failure and scope

`OperationalDataContinuity.workspaceAccess` previously treated a nonempty local
store as sufficient for staff and bypassed the check for administrators.
`ContentView.refreshCompanyOperationalRecordState` only counted records. Neither
proved the records belonged to the authenticated business. Both heuristics are
removed in this candidate; administrator status does not bypass store proof.

The entry paths identified during review were:

- `GunnAire_OpsApp.buildStartupState` attaches CloudKit and creates starter data
  before application authentication.
- `LoginView` reads and writes user/technician models before workspace validation.
- `GunnAireIntentStore` independently opens the same store for Shortcuts entities.
- ContentView starts upload retries, maintenance and payment polling on appearance.
- `CKAccountChanged` refreshed a notice without invalidating data access.

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

## Implemented native boundary

`CompanyWorkspaceAccessController` is the single owner of the operational
ModelContainer. Normal startup displays login/workspace verification without
opening it. Login exchanges identity only; verified user and starter-template
writes occur after workspace proof. Shortcuts/entity queries obtain that same
authorized container and await an in-progress proof instead of independently
opening the database. Debug-only isolated fixtures and CloudKit acceptance
probes remain separate and are compiled out of Release.

Before opening the store, the app obtains a current opaque Apple/Google business
session, the deployed backend's company/binding/user, and the current CloudKit
user record. It validates the environment from an embedded provisioning profile
or verified StoreKit AppTransaction for store distribution. It never guesses
from Debug/Release, QBO environment, or mere receipt-file presence. Profile
entitlements are an allowlist, not a replacement for signed-artifact validation;
the distribution pipeline must independently verify the actual code-signature
CloudKit entitlement agrees. No automatic StoreKit refresh/login prompt is used.

The device-only Keychain registration contains backend origin, the complete
immutable binding, and the actual SQLite `NSStoreUUIDKey`. The UUID is read via
read-only Core Data metadata before ModelContainer attachment. This replaces
the proposed new CloudKit model marker: it does not add a record type, change
the operational schema, or require schema promotion for this local anchor.
A copied/restored foreign database with a different UUID is denied to staff
and administrators. This anchor does not attest the contents of a maliciously
modified SQLite file; data-integrity or compromised-device attestation is not
claimed.

An existing unregistered store requires explicit, default-off administrator
ownership confirmation and the backend's fresh-session approval. A registered
store cannot be relabeled through onboarding. A new empty device can create its
local replica only after matching an already approved backend/account binding.
No existing records, store files or registrations are deleted by denial,
logout, expiry or account change.

The cached lease binds the full business session (including token fingerprint,
email and expiry), origin, company, role, replica, account and environment.
It expires at the earlier of session expiry and 24 hours after server proof.
Offline fallback is limited to transport failure; HTTP denial, malformed data,
changed company/account and missing registration never fall back. The app must
still obtain the current CloudKit identity. If Apple cannot provide it offline,
the gate preserves saved work but does not expose it. Cold offline availability
on signed devices is consequently an explicit acceptance requirement.

A deadline task and foreground/system-clock checks remove the mounted workspace
when access expires or the session changes. Concurrent app/Shortcut checks share
one proof task. Late proofs cannot reopen a replaced/revoked session.
`CKAccountChanged` invalidates access centrally and requires a process restart.
Pending Handoff/Shortcut routes are cleared on invalidation. Changed server
roles advance the access generation and recreate operational navigation, closing
old sheets. Backend business requests check this generation and session before
send and after response; only identity establishment and captured-session
logout/push-device cleanup are exempt. Endpoint classification is relative to
the API, so a configured URL path prefix does not turn login into a gated call.

## Remaining isolation and operational acceptance

- Audit higher-level Google/QuickBooks workflows and retained model contexts
  across callback/async delivery. The direct transport, pagination, retry and
  upload boundaries are now guarded, but they do not prove that an old retained
  model cannot start a new operation after a session change. Durable unconfirmed
  payment-attempt recovery also remains open.
- Prove the lifetime of SwiftData/Core Data mirroring after an account change
  and queued writes on a physical device. Removing UI/container references does
  not by itself prove that internal mirroring has drained or detached.
- Review locally synchronized role records and the legacy primary-admin email
  special case against the current backend role. The gate requires an active
  known server role but is not a complete role-enforcement audit.
- Verify exact signed Development and Production environments, first approval,
  retained populated/empty stores, revoked access, unsynced work retention,
  restoration/reinstallation, and CloudKit convergence on the company iPad/Mac.
- Preserve device-only registrations and company tables during recovery. A
  replacement device or lost Keychain registration needs an explicit data review;
  do not remove or overwrite saved records to make onboarding succeed.
- Employee-owned independent iCloud accounts and switching between distinct
  businesses need a sharing/tenant migration design. This candidate retains
  the approved company-owned-account topology and does not claim to solve them.

## Verification and release acceptance

Retained contract-stage verification: 87/87 backend tests, 37/37 release/tool tests, and
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

Runtime fixture coverage now exercises populated foreign-store denial for staff
and admin, retained legacy data and explicit confirmation, empty approved-device
creation, account/origin/company mismatch, SQLite metadata stability, offline
lease boundaries, HTTP-denial behavior, concurrent checks, late-session results,
clock rollback, expiry without navigation, permission changes and revocation.
Entry-boundary checkpoint verification: **743/743 logic tests and 6/6 UI journeys**
on the 13-inch M5 iPad Simulator (iOS 26.2), zero failures or skipped tests.
The six journeys cover the mismatched-workspace gate and sign-out recovery,
all primary admin destinations, existing-invoice line-item editing, direct
Invoice launch, reachable field-payment Handoff, and simple Mail actions.
These UI journeys use isolated fixtures and do not contact live providers.
The logic suite includes 22 runtime workspace tests plus three contract tests.

Mac Catalyst Debug and optimized Release builds both succeed for arm64/x86_64.
Both retain the pre-existing Xcode Metal-toolchain search-path linker warning;
neither records a source compiler error. Release startup compiles without the
debug-only early-store path. No distribution signing or physical installation
was performed. The simulator emits a LinkDaemon AppShortcut-parameter refresh
diagnostic in the unsigned test host; the passing entity/policy tests do not
claim signed Siri/Shortcuts discovery acceptance.

Retained result:
`/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-06/Company Workspace iPad Logic and Navigation.xcresult`.
Companion logs in that directory are `company-workspace-ipad.log`,
`company-workspace-mac-debug.log` and `company-workspace-mac-release.log`.
Original iCloud workspace and review clone are byte-identical for the candidate
source files; the test project uses the same original sources through symlinks.

Before deploying this additive migration, verify an off-host database backup and
restore test. Preserve both new tables during code rollback. A missing company
identity with an existing approved binding returns an error and startup refuses
to generate a replacement identity. Restore the original database; do not
manually delete binding rows to evade that safety check.

Apple references:

- [Fetching the current CloudKit user record](https://developer.apple.com/documentation/cloudkit/ckcontainer/fetchuserrecordid(completionhandler:))
- [CloudKit synchronization and account configuration](https://developer.apple.com/documentation/technotes/tn3164-debugging-the-synchronization-of-nspersistentcloudkitcontainer)
- [CloudKit containers and signed environments](https://developer.apple.com/documentation/cloudkit/ckcontainer)
- [Provisioning profiles and their entitlement allowlist](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
- [Verified store distribution transaction](https://developer.apple.com/documentation/storekit/apptransaction/shared)

Apple documents that private-database replication uses the same iCloud account
across devices, whereas CloudKit sharing supports separate owner/participant
accounts. Supporting employees' independent personal iCloud accounts remains a
separate architecture requirement; this contract does not implement sharing.
