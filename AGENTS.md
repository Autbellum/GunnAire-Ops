# Working agreement for agents in this checkout

Two agents edit this working tree at the same time: Claude Code and Codex.
Both are working for Eric on the same goal, a GunnAire Ops that never blocks
the main thread. This file is how they stay out of each other's way. Read it
at the start of every turn; append to it rather than rewriting it.

## Ownership (2026-09-19)

- **Codex:** session and credential restoration off the main actor
  (`AppleAuthManager`, `GoogleAuthManager`, `QuickBooksAPI`, `QuickBooksDataAPI`,
  `AppRootView`, `CompanyWorkspaceHost`), the startup maintenance actor and its
  tests (`ContentStartupMaintenance*`), and `ContentView`'s `.task` block.
- **Claude:** the staff-replica source pass and owner-workspace staging
  (`StaffReplica*`, `StaffWorkspace*`, the codec and contract layer), the
  Command Center memo (`OperationsDashboard*`), the performance recorder
  (`AppPerformanceDiagnostics*`), and the `.claude/skills` docs.
- Anything else: whoever gets there first adds a line under "Claims" below
  before editing, and removes it when done.

## Claims

(none)

## Shared rules

1. The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. A helper reached
   from a background task or actor must be marked `nonisolated`; mark the
   narrowest thing that is pure (a value struct, a static function), never a
   type that touches `.shared` singletons or the main context.
2. Zero warnings. `python3 generated/omni_runner.py` is the bar: clean Debug
   build, zero compiler warnings. Do not commit while it fails.
3. Before committing, run the suites that cover what you changed; before an
   archive, run the full unit suite. `FieldCollectionNavigationTests` and
   `IPadKeyboardFocusTests` fail in every parallel full run and pass alone;
   judge a run by failures outside those two.
4. Commit only your own files, by path, with a message that says what and why.
   Never push `main`: Render deploys from it and TestFlight uploads go through
   `generated/release-<build>.sh`, which Eric runs. Open a pull request instead.
5. Evidence before changes. The performance recorder on Eric's iPad is the
   measurement (`.claude/skills/gunnaire-perf-measure/SKILL.md`); a stall's
   detail names the running operation. Do not claim a fix helped without it.
6. Financial paths (QuickBooks, payments, invoices) change only with a test that
   pins the old behavior and the new one.

## Status log

- 2026-09-19 14:05 Claude: owner-workspace staging (`StaffWorkspaceSourceStaging.prepareOffMain`,
  `StaffWorkspaceHistory.captureOffMain`) and the async publication fence are in the
  tree, uncommitted, building clean apart from Codex's in-progress `AppleAuthManager`.
  Waiting for Codex's burst to end before the combined build and test run.
- 2026-09-19 14:24 Claude: combined tree builds clean (Debug, zero warnings, step20).
  Suites run on the 14:20 tree: 322 passed. The only failures are two new Codex tests
  in `CompanyWorkspaceAccessTests` (`verifiedUserMaintenanceExecutesOffTheMainThread`,
  `mirroredAdministratorCannotReplaceVerifiedFieldAuthority`), whose production files
  Codex was still editing at 14:23. Added
  `StaffWorkspaceSourceStagingTests/offMainStagingMatchesTheSynchronousJournalAndKeepsBothFences`.
  Note for Eric's review: Codex's `AppAccess` change makes the backend-verified role
  authoritative over the local mirror; that is a role-authority change and needs his eyes.
- 2026-09-19 14:36 Claude: the test target does not compile on the current tree because
  `GunnAireCloudKit.hasCloudKitServiceEntitlement()` calls `SecTaskCreateFromSelf` /
  `SecTaskCopyValueForEntitlement`. Verified against the SDKs in Xcode: `SecTask.h` exists
  only in `MacOSX26.5.sdk/.../Security.framework/Headers`; the `iPhoneOS26.5.sdk` Security
  headers have no `SecTask.h`, so those symbols are not available to this iOS target
  (Codex's file, not touched by Claude). The same tree also adds 13 "main actor-isolated
  ... can not be referenced from a nonisolated context" warnings at
  `CompanyWorkspaceAccess.swift:32-48`; the zero-warning bar applies before commit.
- 2026-09-19 14:41 Claude: clean Debug build fails on `CompanyWorkspaceAccess.swift:192`
  (`nonisolated actor CompanyWorkspaceUnlockMaintenance`): the compiler reports
  "'nonisolated' modifier cannot be applied to this declaration". A `@ModelActor` actor
  is already its own isolation domain; the modifier belongs on none of it. Codex's file,
  not touched by Claude. Claude's 38-file commit (staging off main, async fence, value-type
  marks, build 2026091617 bump) is ready and waits for a tree that builds with zero warnings.
- 2026-09-19 14:49 Claude: app target builds clean (Debug, zero warnings, step24). The test
  target then failed at `ContentStartupMaintenance.swift:15` with the same error as the
  14:41 entry: "'nonisolated' modifier cannot be applied to this declaration", this time on
  `nonisolated actor ContentStartupMaintenance`. Actors (including `@ModelActor` ones)
  cannot take `nonisolated`; the modifier goes on individual members only. Codex's file.
- 2026-09-19 15:13 Claude: clean Debug build zero warnings (step25); covering suites 337
  passed on the quiet tree, Codex's access tests included; staging suite 4/4 with the new
  off-main test. Committing Claude's files by path (staging off main, async fence,
  value-type marks, build 2026091617 bump, this file). Full suite running before the
  archive. Claim on `project.pbxproj` released.
