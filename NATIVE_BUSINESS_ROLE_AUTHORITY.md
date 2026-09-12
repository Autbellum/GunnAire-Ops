# Business role authority and CloudKit sharing boundary

Source checkpoint, September 8, 2026. This is not independent-staff sharing,
production deployment, or full-suite acceptance.

## Confirmed defect and correction

`AppAccess.activeRole` granted Admin to a hard-coded email before checking any
user record. Other accounts received roles from synchronized `AppUser` records
without comparison to the approved business-session role. Startup and roster
refresh could also invent a missing local administrator. Server-side provider
checks did not make these local navigation and mutation decisions authoritative.

Live access now requires a current workspace lease, the exact signed-in user,
an active known server role, and agreement from every matching local user record.
Email comparison is normalized consistently. Empty identities, missing records,
inactive or conflicting duplicates, unknown role values, expired leases and
different users fail closed. There is no email-based privilege exception.
Startup and roster refresh no longer create unapproved administrators.

The role policy is pure: it performs no network call or SwiftData fetch while
SwiftUI renders. `CompanyWorkspaceAccessController.verifiedUser` supplies only
the current bounded server lease. Existing workspace/account/store proof,
generation invalidation, session expiration and original-operation checks remain.
A failed or ambiguous role check shows one focused **Verify business access**
page with **Check Again**. Refresh uses the existing workspace owner and repairs
the current user's mirrored role from the verified server response; no role is
inferred from the primary email or a locally edited record.

Task-assignee lists no longer invent the primary administrator or include
ambiguous/inactive identities. Time Clock requires an active role, preserves
the existing owner/accounting personal-clock restriction, and checks the current
owner and open-entry state before clock-out or context edits. Timesheet sign-off,
office export and QBO publication entry points recheck their existing role
boundary. This is not a migration of the remaining device-OAuth time publisher.

Debug-only isolated tests retain their local fixture roles, but no implicit
primary-email privilege. The release path has no fixture fallback. Eight pure
policy tests explicitly exercise the live verified-user decision and time
boundaries. Two real workspace-controller harness tests verify that mirrored
promotion cannot replace the server role, refresh restores the verified role,
and expired/revoked authority cannot be recovered from retained user records.

## Qualification

Evidence: `/Users/gunnaire/Downloads/GunnAire Ops Releases/2026-09-08/Role Authority.QnP6iF`.
`FinalMac3.xcresult` passes all **1,558** logic tests with zero failures/skips;
the actual-execution verifier confirms the complete requested logic target.
All **56** Tools tests and both workflow lint checks pass. The workflow now
names **60** UI journeys split once across two disjoint, balanced groups.
`FinalRelease2.log` reports an unsigned universal Mac Release, verified as
**arm64 + x86_64**. Its binary SHA-256 is
`892ad5e0d40210713e4954af86f07e8af375baae668d48bcf54c432314ec4a93`.
App sources are unchanged after that build; the later mail-route correction is
test-only. Existing document-concurrency and optional Metal-path warnings remain.
`FinalIPad2.xcresult` passes **1,569** actual tests: **1,558** logic tests and
**11** UI journeys, with zero failures/skips. The actual-execution verifier
confirms all **12** requested target/method selectors executed. All **8** final
screenshots are visually reviewed: existing-link selection and cancellation,
technician time sign-off, focused access recovery, and simple Mail inbox,
message, compose and recoverable Trash confirmation. None has an account-email
footer or raw API diagnostics. This is local qualification; the published head
still requires its own hosted CI results.

The first Mac run identified two old positive tests that relied on the implicit
administrator grant. They now provide an actual active Admin fixture; the
missing-record case explicitly denies access. No permission assertion was
weakened to retain the old grant. The new iPad journey checks inactive-primary
account denial, visible recovery, absence of admin navigation, and a separate
renewed-access fixture launch. It does not simulate a successful live server
response. The CI selector adds that journey while retaining all existing cases.

The retained iPad diagnostics identified two separate issues. The recovery page
was visible, but the outer SwiftUI identifier propagated to its children and
hid the button's identity. An explicit
[accessibility container](https://developer.apple.com/documentation/swiftui/accessibilitychildbehavior/contain)
now retains child controls and passes the recovery journey. The other failure
occurred only after the full logic target: the mail-draft routing test consumed
its draft but left the Mail route pending. The Accounting failure screenshot
shows the correct **Access Restricted** alert over an otherwise valid Find UI.
The test now consumes and asserts the original route and verifies no route
remains. Production role restrictions and routing behavior are unchanged.
Failure-only screenshot and accessibility attachments remain available for
future regressions; the final suite passes without dismissing an unexpected
alert or weakening the Find assertion.

`VerifiedOriginalPreflight.json` records **14** scoped paths, **260** unrelated
original-project changes, the unchanged index, and **298** other byte-identical
tracked source files. Copy-back must preserve those boundaries and verify every
scoped file byte-for-byte; no database or app installation is part of the copy.

## Independent-staff CloudKit architecture remains required

Authoritative current source has one private SwiftData CloudKit replica and one
immutable approved account binding per environment. It contains no `CKShare`,
shared-database consumer or role-filtered operational replication service.
Removing the account-hash check would neither share records nor isolate staff.

[Apple's SwiftData configuration](https://developer.apple.com/documentation/swiftdata/modelconfiguration/cloudkitdatabase-swift.struct)
provides automatic/private/none; [CloudKit sharing](https://developer.apple.com/documentation/cloudkit/shared-records)
supports explicitly invited participants and record subsets. Write permission
permits changes and deletion throughout the included share. A company-wide
read/write share cannot implement technician, dispatch and accounting policy.
This architecture conclusion combines those documented semantics with the
observed app schema and business-role requirements.

The proposed multi-user direction is a server-authorized operational change
stream, partitioned by company and current staff assignment, with durable
idempotent local intents and explicit conflict rules. CloudKit remains a durable
per-approved-principal replica, not role authority. This must be designed and
migrated as one system, not enabled by relaxing the existing binding:

1. Confirm company-managed versus independent staff iCloud topology; the user
   was asked because this changes device enrollment and data ownership.
2. Inventory and classify every operational model and attachment field. Keep
   payroll, costs, provider credentials and unassigned customer data outside
   field replicas. Authorize reads, writes, exports and tombstones server-side.
3. Define canonical revision ownership for schedules, sold prices, billing,
   approvals and deletion; merge only explicitly append-only field evidence.
   Preserve original UUIDs and customer/job/invoice/item relationships.
4. Use a separate scoped local store and durable operation journal. Do not attach
   an existing company-wide store to a new personal iCloud account, silently
   relabel it, delete unsynced work, or synchronize credentials through CloudKit.
5. Require reviewed bootstrap, encrypted backup/restore, reconciliation, and
   rollback before cutover. Migrate actual workflow entry points, not a second
   disconnected editor or an unused sync endpoint.
6. Prove two independent signed accounts, iPad/Mac convergence, offline changes,
   reassignment/revocation, device replacement, exact QBO identity preservation,
   and physical iPhone payment handoff. Fixture tests cannot prove these gates.

No signing, entitlement, schema promotion, production roster, live provider,
customer message, payment, device installation or deployment changes are included.
