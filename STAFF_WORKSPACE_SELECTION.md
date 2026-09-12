# Full-workspace server record selection

This implements server-enforced **record identity selection** for all 32 owner model kinds. It does not send business field values, deliver media, import a staff store, or authorize a staff lease. Field projection remains mandatory. The native six-kind receiver is unchanged and must not treat an index as a complete operational workspace.

## API and authority

Backend source version: `2026.09.09.51` (local candidate, not deployed).

- `POST /api/workspace/staff-shares/{shareID}/full-selections` prepares an immutable index. Its exact body is `companyID`, `environment`, `replicaID`, `operationID`, `expectedSourceSequence`, `expectedShareRevision`, and `sourceSchemaDigest`. Revisions are positive integers, not booleans. Duplicate JSON keys and unknown fields fail.
- `GET /api/workspace/staff-shares/{shareID}/full-selections/{operationID}` recovers its original receipt. Required query fields: `companyID`, `environment`, `replicaID`.
- `GET /api/workspace/staff-shares/{shareID}/full-selections/{operationID}/records` returns up to 100 ordered index entries. Continue with the returned `after` cursor; `nextCursor: null` ends the collection. Unknown cursors and duplicate query fields fail.

All operations require an active Admin application session, including when the target staff member is the caller. Authentication, current company/replica binding, accepted share, membership revision, approver authority and eligibility are rechecked inside the database transaction. The saved share policy must exactly match the current member role before preparation or recovery. An index is owned by its exact creating administrator, company, environment, replica and share. Reusing its operation ID with changed input cannot replace it or change its owner.

The encrypted `staff_workspace_selections` table is additive. It uses the existing authenticated owner-storage encryption key; no new credential is required. No owner source record, original selection, or receipt is pruned or rebuilt after a failed recovery. Database backup/restore includes this table, but a production index-retention policy is still required before high-volume rollout.

Any owner source change makes original index data pages unusable. The original receipt remains recoverable with `sourceCurrent: false`; a fresh operation must select from the new source. A source sequence rolled back behind an already-committed selection fails as storage recovery, not a new empty success. Membership deactivation, role changes, share revocation or approver demotion prevent continued use. Changing selection policy semantics requires a new selection schema version; do not reinterpret retained indexes under different rules.

## Explicit selection rules

Each index entry is only `kind`, original `id`, original `revision`, and `unavailableLinks`. No source names, notes, costs, credentials, provider payloads, message content, or field-value digest appears in the index. Every response identifies the complete 32-kind schema coverage and explicitly returns `fieldProjectionRequired: true`, `operationalWorkspaceReady: false`, and `localCloudKitProofRequired: true`.

| Role | Record candidates before field disclosure |
| --- | --- |
| Admin | All live records; never retained tombstones |
| Dispatcher | Company operational/dispatch, estimates, availability/time-off review, tasks, fleet and related purchasing/material records; own time and expense records; no invoice or payment ledger grant |
| Accounting | Billing/reporting, time review, expenses, materials/purchasing and fleet records, with their customer/job/equipment context; own user/tasks; no time-off/private dispatch review grant |
| Field Technician | Lead/crew-assigned jobs, their customer/property/equipment scope, assigned-job invoices/payments, approved/archived or own-draft items, own workforce/time/expense/task records, required forms, relevant agreements/alerts, assigned vehicles and unambiguous truck stock, related supply records and authorized files/messages |
| Standard | Own user, time entries, tasks and task events; no implicit company directory or billing grant |

This table is **not** permission to copy raw candidate fields. For example, accounting may need ledger context but not operational notes; field technicians need parts and sold lines but not purchase/labor costs; self-scoped expenses need their own amount but do not grant another employee's financial records. `STAFF_BILLING_DISCLOSURE.md` describes the existing native typed billing component. Equivalent reviewed field adapters for the remaining domains and server enforcement of those adapters remain required.

The source graph is schema/digest pinned, rejects duplicate identities, validates every typed model reference and the declared crew/equipment UUID lists, detects transitive customer/technician/invoice/fleet lineage conflicts and cycles, and verifies property/equipment consistency before selection. Original opaque domain JSON is not certified as business-valid by this identity index; domain adapters must validate it before disclosure. Group/operation UUIDs do not create record grants. Missing or duplicate field technician identity fails instead of returning a misleading empty work list.

An owned time entry/task/expense can outlive a job assignment. Its out-of-scope model links appear in `unavailableLinks`, not as fabricated nil values or extra record grants. Own expense receipts remain available after reassignment while the old customer/job stay unavailable. A permitted job or receipt cannot expose a file or message with another restricted invoice, expense, equipment or fleet parent. Financial account-statement files remain financial even under the generic customer-document kind. Ambiguous truck stock locations block field stock selection rather than merging multiple vehicles.

## Verification and preservation

Evidence root: `/Users/gunnaire/Downloads/GunnAire Ops Releases/Full Staff Selection.3n9zAB`.

- `Focused1`: 24 new policy/HTTP tests passed (intermediate source).
- `Related2`: 134 selection, owner-source, sharing, core-replica and entrypoint tests passed (before the final deep-history/source-rollback cases).
- `Focused3`: 31 policy/HTTP tests passed before the final policy-consistency case, including the complete native 32-kind fixture and a 2,001-job history without truncation or recursive stack traversal.
- `BackendFull1` (Python 3.9.6) and `BackendPython312` (Python 3.12.14 with cryptography 50.0.1): each passed all 912 then-existing backend tests. These are intermediate evidence before the final policy-consistency guard/test.
- `PolicyReproduction1`: one deliberately added test failed with `200 != 403` when a test-database policy label was corrupted to disagree with its still-current role. Record identities remained role-filtered and no business field values were exposed. Root cause: authority trusted the saved policy label without checking it against the role. `PolicyReproduction2` passes the unchanged test after adding that exact comparison.
- `BackendFull2` (Python 3.9.6): all 913 final backend tests passed in 153.937 seconds. `BackendPython312Final` (Python 3.12.14 with cryptography 50.0.1): all 913 final backend tests passed in 153.751 seconds. Both process handles closed with exit 0; neither suite reports failures or skips. These runs include the policy-consistency guard and unchanged regression assertion.
- `Tools1`: all 75 tooling tests passed. Hosted Python 3.13/3.14 CI is not claimed; those runtimes are unavailable locally and the branch has not been pushed.
- Native Swift, Xcode settings, entitlements, signing and UI code are unchanged in this checkpoint. The previous 1,915-unit iPad and unsigned iOS/Mac evidence remains evidence for those unchanged native files, not proof of live staff delivery.

`OriginalPreflight2.json` protects the six scoped files, 431 unrelated owner changes and the original branch/HEAD/index, with 420 other tracked sources byte-equal. `OriginalCopyBack1.json` confirms all six copied files are byte-equal, all 431 unrelated changes are preserved, and the owner's branch/HEAD/index are unchanged. The owner checkout is not staged or committed; only the isolated review checkout is committed. `OriginalCopyBack2.json` rechecks equality and protection after this evidence update.

The live skill audit is `/Users/gunnaire/.codex/skill-audits/skill-usage.jsonl`. Access-control/API guidance drove server-side current-authority checks and exact immutable contracts; HVAC, inventory, dispatch, communications and payments guidance separated work, financial, personal and file scopes; offline/reliability guidance preserved original operations and denied stale indexes. Troubleshooting guidance added the retained policy-mismatch reproduction, exact correction, unchanged regression assertion, and explicit limits on what the issue exposed.

## Remaining full-suite work

This endpoint is not yet called by the native full-workspace publication path. Required next integration is to combine the server-selected identities with complete, explicitly validated role-field projections; issue immutable role-filtered content; implement staff read/write adapters, durable commands and media access; and activate only with an authenticated staff lease plus independent signed CloudKit proof. Full independent-account convergence, QBO/Google/vendor/payment acceptance, physical iPad-to-iPhone Tap-to-Pay handoff, and the broad competitor-feature/navigation/accessibility/performance audit remain unfinished.

No production deployment, live business/accounting/customer/vendor mutation, credential expansion or Apple configuration occurs here. GitHub publishing still awaits the workflow-token permission. All work is background-only: no screenshots, recording, screen inspection, browser/tab changes, or foreground application tests.
