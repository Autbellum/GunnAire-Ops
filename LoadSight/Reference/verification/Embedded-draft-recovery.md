# Embedded mechanical draft recovery

The Ops-hosted mechanical workspace now retains committed project edits in local recovery storage. A draft is separate from a portable `.loadsight` or JSON export. The header acknowledges a local save only after persistence succeeds for the current project/drawing state. A new or imported project without edits does not create a recovery copy.

Opening the host offers Restore local draft or explicit discard when a saved draft exists. Closing edited work offers Keep draft and close, Discard changes, or Keep editing. Keep draft and close waits for the latest queued save and refuses to close as saved when persistence fails. Export remains the portable project workflow; a completed export clears only the appropriate recovery state, while newer edits retain their draft. Returning a project to its clean/exported state removes a superseded recovery copy.

## Storage and access boundary

`WorkspaceRecoveryStore` is a Swift actor with atomic file replacement, a per-scope interprocess file lock and expected-revision comparison. Cooperating windows/processes cannot overwrite or delete a newer draft with an old revision. The envelope includes a version, revision UUID, account-scope digest, save time, complete project state and original drawing archive. Inline drawing duplication is removed; source bytes, hashes, RFI/CO/QA and Ops-link histories remain in the snapshot. Loads validate both the project and drawing evidence before exposing a restored document.

The Ops host supplies a scope derived from its CloudKit container, normalized current user email, QuickBooks environment and configured realm (or local-account marker). Debug UI fixtures instead use their isolated test-store UUID. Account-context changes recreate the host session. The existing financial-detail access check gates entry. The SDK itself does not authenticate users or authorize server access; hosts must supply their authorized context. Recovery does not synchronize with Ops, CloudKit, QuickBooks or another device.

Files live in the application's Application Support directory, using hashed scope filenames, a private directory and owner-only file permissions. iOS writes use complete file protection. Symlink/non-regular files, scope mismatches, invalid history, corrupt data and unsupported envelope versions are rejected rather than replaced. Read failures leave the prior bytes in place; the user may retry or explicitly continue without local recovery and export new work. No encrypted cross-device backup or power-loss guarantee is claimed. Work not yet acknowledged as saved may be absent after termination; the save status makes that distinction visible.

## Verification

`output/verification/recovery-tests-final.log` records 157 passing shared tests, including eight recovery tests. They exercise actual disk round trips with drawing originals and Ops history, separate account scopes and scope-mismatched files, competing store instances with one revision-check winner, stale save/delete rejection, corrupt and symlink preservation, delayed export/newer-edit retention, clean-state removal and failed-storage reporting. The native Mac bundle build passes (`output/verification/recovery-mac-build.log`).

The final iOS 26.2 iPad simulator run passed both explicitly selected tests: `testCustomerJobLinkAndUnsavedProjectGuard` (24.12 seconds) and `testLocalDraftRecoversAfterTermination` (37.49 seconds). The latter saved a synthetic job link, terminated and relaunched the app, restored the draft, kept and reopened it, then explicitly discarded it and confirmed a fresh workspace. Both final screenshots were visually inspected. The first run restored correctly but stopped on a duplicate SwiftUI accessibility match for the keep button; the test now uses the first matching button, and the complete rerun passes.

Evidence is retained locally in `output/verification/recovery-native/`: exact test-results JSON, full final log, two screenshots and a 66-file SHA-256 source manifest verified against the isolated build copy. The result bundle is `/tmp/gunnaire-loadsight-recovery-ui-final.xcresult`. CI includes the restart test in iPad shard zero. Both workflow YAML files and all 11 embedded shell steps pass local syntax checks; hosted CI has not run.

Native export-dialog acceptance, physical-device suspension/power-loss testing, multi-window UI interaction, authenticated publication and broader engineering methods remain additional work. This feature does not complete the full application objective.
