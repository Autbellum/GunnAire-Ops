---
name: gunnaire-ship
description: How to ship, verify, and roll back a GunnAire Ops TestFlight build. Use for any release, for a rollback when a build misbehaves on Eric's devices, and for the checks that must pass first. Encodes the exact commands, the build-number convention, and the one rule that protects his production iPad.
---

# Shipping GunnAire Ops

Eric runs TestFlight builds as production on his iPad and iPhone. A push to `main`
also deploys the Render backend (bump `SERVICE_VERSION` in
`Backend/gunnaire_backend.py` when backend code changes so `/health` can confirm
it). Every xcodebuild, devicectl, and xctrace call needs the Bash sandbox disabled.

## Before shipping

1. Full unit suite on the simulator (`147D4CB6-85CC-4B17-BD35-8684E60E672D`):
   `xcodebuild test … -only-testing:"GunnAire OpsTests"`. Count with
   `grep -c "' passed on"` and `grep -c "' failed on"`; a test whose *name* contains
   "failed" is not a failure. `IPadKeyboardFocusTests` is timing-flaky in full runs
   and passes alone; rerun it alone before treating it as a regression.
2. If the change touches access control, billing, or sync, the specific suite for
   that boundary must pass unchanged (for workspace access:
   `CompanyWorkspaceAccessTests`).
3. If the change claims a performance effect, it needs a measured before and after
   per `gunnaire-perf-measure`; a number from a denied or empty workspace does not
   count.

## Build numbers

`CURRENT_PROJECT_VERSION = YYYYMMDDNN` in `GunnAire Ops.xcodeproj/project.pbxproj`,
six occurrences. Sed them all and assert the count is 6 before and after.

## The chain

Commit, bump, `git push origin main`, then:

```
xcodebuild archive -project "GunnAire Ops.xcodeproj" -scheme "GunnAire Ops" \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath <tmp>/GunnAireOps-<build>.xcarchive -allowProvisioningUpdates \
  -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_7YBP3GY874.p8 \
  -authenticationKeyID 7YBP3GY874 -authenticationKeyIssuerID 08292696-bd8c-4732-9976-2ad43c1a39aa
xcodebuild -exportArchive -archivePath <same> -exportOptionsPlist TestFlightExportOptions.plist \
  -exportPath <out> <same three authentication flags>
```

**Sync `main` before the push, verified 2026-09-20.** The release script pushes
`main` because Render deploys from it. When the pull request was merged on
GitHub, the local `main` ref is behind and `git push origin main` is **rejected**
as a non-fast-forward ("Updates were rejected because the remote contains work
that you do not have locally"), so with `set -euo pipefail` the release stops
before uploading. It is not a no-op; that was assumed once and was wrong. Run
`git fetch origin main:main` first (safe while another branch is checked out,
fast-forward only), then push, which reports "Everything up-to-date" in the
merged case. Confirm with `git push origin main --dry-run` before believing it.

Success is `** ARCHIVE SUCCEEDED **`, `** EXPORT SUCCEEDED **`, and a line
containing `Upload succeeded`. About twelve minutes end to end; run it as one
background job and watch the logs. App id 6758308973 for App Store Connect queries.

## Rolling back

To give Eric a known-good build without touching `main`: `git worktree add --detach
<tmp> <good-commit>`, bump the build number *in the worktree* to the next free
number, archive and export from the worktree, then `git worktree remove --force`.
Done on 2026-09-18 as 2026091614 from 63f404c. A rollback that is *also* slow proves
the cause is device state, not the code; that is useful evidence, say so.

## The rule that protects his iPad

Never install a dev-signed (debuggable) build on Eric's iPad or iPhone. It flips the
CloudKit environment the app reports to "development", the workspace runs denied,
and switching back to TestFlight has twice triggered a store loss or full re-import
that froze the app on his real data. Profiling belongs on a simulator or a device
that is meant to be a development workspace. See `gunnaire-perf-measure`.
