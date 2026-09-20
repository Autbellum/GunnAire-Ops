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
- 2026-09-19 15:16 Claude: committed b2b71a9 (40 files) on
  `perf/command-center-memo-and-launch-off-main`, pushed, pull request #26 open against
  main with 6 CI checks pending. Full unit suite running (896 passed, 0 failed at 15:15);
  the 2026091617 archive follows it. Codex's 28 modified files are untouched and
  uncommitted; `generated/omni_runner.py` (one-line message edit, 14:51) is among them.
- 2026-09-19 15:22 Claude: full suite on the mixed tree: 2586 passed, 8 failed (7 in the
  known-flaky `FieldCollectionNavigationTests`, 1 in Codex's uncommitted
  `CompanyWorkspaceAccessTests/cloudKitTimeoutDoesNotWaitForAnOperationThatIgnoresCancellation`,
  which passed in the solo covering run at 15:05; a timing test under the parallel run).
  Building the committed state alone in a detached worktree showed one warning the mixed
  tree hid: the `nonisolated` mark on `QuickBooksDocumentLinePublication.validateSnapshotTotals`
  lives in `QuickBooksManagementView.swift`, which the commit had left out. Committed that
  single line as 6b85821 from the HEAD blob; Codex's working-tree edits to that file are
  untouched. The disk hit 100% full during the worktree link step (544 MiB free); Claude
  removed only its own DerivedData (4 GB). Archive 2026091617 is built from the worktree,
  so it contains exactly the pull request, none of the uncommitted work.
- 2026-09-19 15:34 Claude: the committed branch alone (worktree at 9390915, which adds the
  `currencyCents` mark that the `validateSnapshotTotals` mark exposed) builds with zero
  warnings; covering suites there 402 passed, 0 failed. Pushed; pull request #26 body updated
  with the verified results. Archive 2026091617 building from that worktree into
  `/var/folders/.../T/ship-2026091617`. Eric runs `generated/release-2026091617.sh` after
  merging #26. Codex's `cloudKitTimeoutDoesNotWaitForAnOperationThatIgnoresCancellation`
  still to be rerun solo once the archive frees the disk.
- 2026-09-19 15:41 Claude: archive 2026091617 built from worktree commit 9390915 with zero
  warnings (`/var/folders/.../T/ship-2026091617/GunnAireOps-2026091617.xcarchive`,
  CFBundleVersion 2026091617). Pull request #26 head is a73bbf2 (docs only on top of
  9390915). Claude's DerivedData directories are removed after each step because the disk
  is at 100%; the only remaining large item of Claude's is the archive itself.
- 2026-09-19 15:44 Claude: Codex's `cloudKitTimeoutDoesNotWaitForAnOperationThatIgnoresCancellation`
  passed in the 15:05 covering run (0.30-0.41 s) and failed once under the parallel full
  run; a method-level `-only-testing` rerun selected no test (xcodebuild matched nothing),
  so the evidence is: timing-sensitive under load, not a deterministic failure. Codex's
  call whether to widen its deadline. Claude's work for build 17 is complete; the
  worktree at `/tmp/claude-502/wt17` stays until the release in case a re-archive is needed.
- 2026-09-19 19:52 Claude (the Mac slept from about 15:56 to 19:50): the review on #26 found two real defects in Claude's files, fixed
  in one commit: the owner-workspace key loader read raw bytes while builds up to 16 stored
  the key JSON-encoded through `KeychainStore.saveCodable` (an upgraded install would have
  failed the 32-byte guard and lost access to its encrypted staging journal), now handled by
  `StaffWorkspaceSourceStaging.ownerKey(fromStored:)` with a test; and the release script
  piped `git push` into `tail`, masking a failed push under `set -e`, now `set -euo pipefail`
  with an unpiped push. Two other findings were declined with evidence (archive timeline;
  the persist window in `prepareOffMain` is the same post-prepare window that already
  exists before the remote read). Archive 2026091617 is being rebuilt from the fix commit.
  Lesson for both agents: when a keychain or file entry changes its encoding API, the
  reader must accept the previous representation until every device has rewritten it.
- 2026-09-19 20:05 Claude: archive 2026091617 rebuilt from 6c8df18 (zero warnings) and the
  superseded 9390915 archive removed; pull request #26 body updated; all four review threads
  answered (two fixed, two declined with evidence) and resolved. Disk: the 660 GB that `du`
  reported under `~/Library/Developer/XCTestDevices` (267 leftover parallel-test simulator
  clones, July 19 to today) was deleted, but the volume's used space did not move, so that
  figure was `du` counting APFS clone files that shared blocks with the base simulators;
  the real consumer of the 940 GB is still being located with a volume-wide scan.
- 2026-09-19 20:15 Claude, correcting the 20:05 entry: the 660 GB of leftover parallel-test
  simulator clones was real data, not a `du` overcount. `simctl delete` moves each device's
  data to `$TMPDIR/Deleting-<UUID>` and CoreSimulator reclaims it asynchronously; the 290
  such folders, all stamped 19:58, are that reclamation in progress (free space 8 -> 25 GiB
  so far). Root cause of the full disk: xcodebuild's parallel-testing clones were never
  cleaned up, 267 of them since July 19. Watch `~/Library/Developer/XCTestDevices` after
  interrupted test runs.
- 2026-09-19 20:36 Claude, final on the disk (supersedes 20:05 and 20:15): the leftover
  parallel-test clones were mostly shared APFS blocks; deleting all 267 returned about
  44 GB (volume used 876 -> 832 GiB), and six stale DerivedData folders from earlier
  sessions under `$TMPDIR` returned 9 GB more. Free space 544 MiB -> 61 GiB. `du` totals
  under CoreSimulator are not trustworthy; use `df`/`diskutil` deltas. Where the remaining
  ~820 GiB lives was not established and is for Eric to look at in Storage settings.
  Rule 6 in `gunnaire-perf-measure` records the cleanup procedure.
- 2026-09-19 21:45 Claude (claim: `GunnAire Ops/SharedTimeUIFixture.swift`, new
  `GunnAire OpsTests/SharedTimeUIFixtureTests.swift`; released on commit): CI's iPad shards on
  #26 failed three shared-time UI tests at the fixture line that waits for the technician
  row. Verified cause, not this branch's code: Team Review defaults to "This Week"
  (`weekOfYear`, device calendar) and filters on clock-in; the fixture clocked in four
  hours before `now`, so any run in a week's first four hours hid the entry. CI runs in
  UTC and ran Sunday 2026-09-20 00:56-01:26 UTC; every passing run was mid-day. Main has
  the same defect every Sunday morning UTC. Fix: `SharedTimeUIFixture.reviewAnchor(now:)`
  keeps the entry inside the current week, pinned by `SharedTimeUIFixtureTests`.
- 2026-09-19 22:25 Claude: on 08feb74 the "Mac native tests" job failed only in its last
  step, "Retain native test evidence": `Failed to CreateArtifact: Unable to make request:
  ENOTFOUND`, a DNS failure on the GitHub runner; every test step passed. Not code. The
  failed job is re-run automatically once the iPad shards finish (GitHub refuses re-runs
  while a run is in progress). If this recurs, the evidence-upload step could take
  `continue-on-error: true`, but that hides lost evidence, so it is left as is for now.
- 2026-09-19 22:50 Claude (claim: one hunk of `GunnAire OpsUITests/GunnAire_OpsUITests.swift`,
  committed from the HEAD blob; Codex's working-tree edits to that file untouched): CI's
  iPad shard 2 on 08feb74 failed `testCatalogEditingControlsStayInsideTheSheetAcrossRotation`
  at the `count == 1` check for `DoneEditingCatalogItem`, taken right after a rotation. The
  same test failed on main at 3a56bc9 and on c1c8cce and passed on 510ca3d: flaky, pre-dating
  this branch. The app declares exactly one such control, so a count of two is a transient
  accessibility-tree state during rotation. The test now waits up to 3 s for the count to
  settle at one and still fails if a duplicate persists. Shared-time fixture fix confirmed:
  those three tests no longer fail.
- 2026-09-19 23:58 Claude: on 4d304d9 the regular iPad shards passed (rotation test included);
  the dedicated "Verify largest-text catalog editing" step failed with XCTest's "Failed to
  determine hittability of DoneEditingCatalogItem: Activation point invalid", thrown from
  `waitForHittable` right after the final rotation back to portrait. Main's own 17:40 run
  died with the identical error, so it predates this branch and is intermittent (the other
  session's branch passed the step at 18:54 on the same app code). `waitForHittable` now
  also requires the control's centre to be inside the app window before asking
  `isHittable`, so the bounded wait keeps polling instead of aborting; a control that never
  returns on screen still fails. One hunk from the HEAD blob; Codex's working-tree edits
  to the file untouched.
