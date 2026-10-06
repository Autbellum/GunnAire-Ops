#!/bin/zsh
# Ship build 2026100501: customer search, Google Calendar sends, write-back of
# imported Google events and automatic retry (PR #28). Run on the Mac AFTER
# PR #28 is merged into main. It does not push anything: it archives the merged
# main and uploads that archive to TestFlight. Install the result from TestFlight
# only; never install a dev-signed build on the production iPad or iPhone.
set -euo pipefail
cd /Users/gunnaire/Projects/GunnAire-Ops
KEY=(-allowProvisioningUpdates -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_7YBP3GY874.p8 -authenticationKeyID 7YBP3GY874 -authenticationKeyIssuerID 08292696-bd8c-4732-9976-2ad43c1a39aa)
BUILD=2026100501
OUT="${TMPDIR:-/tmp}/ship-$BUILD"
mkdir -p "$OUT"

git fetch origin main
WT="$OUT/worktree"
[ -d "$WT" ] && git worktree remove --force "$WT"
git worktree add --detach "$WT" origin/main
cd "$WT"
# The merged main must carry this build number and the PR #28 fix.
[ "$(grep -c "CURRENT_PROJECT_VERSION = $BUILD;" 'GunnAire Ops.xcodeproj/project.pbxproj')" = 6 ] \
  || { echo "origin/main is not build $BUILD; merge PR #28 first"; exit 1; }
grep -q "adoptImportedEvent" "GunnAire Ops/GoogleCalendarScheduleSync.swift" \
  || { echo "origin/main lacks the PR #28 calendar fix"; exit 1; }

xcodebuild archive -project "GunnAire Ops.xcodeproj" -scheme "GunnAire Ops" \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$OUT/GunnAireOps-$BUILD.xcarchive" "${KEY[@]}" > "$OUT/archive.log" 2>&1
grep -E "ARCHIVE SUCCEEDED|ARCHIVE FAILED|error:" "$OUT/archive.log" | tail -4

xcodebuild -exportArchive -archivePath "$OUT/GunnAireOps-$BUILD.xcarchive" \
  -exportOptionsPlist TestFlightExportOptions.plist -exportPath "$OUT/export" "${KEY[@]}" \
  > "$OUT/export.log" 2>&1
grep -E "EXPORT SUCCEEDED|EXPORT FAILED|Upload succeeded|error:" "$OUT/export.log" | tail -4

cd /Users/gunnaire/Projects/GunnAire-Ops
git worktree remove --force "$WT"
