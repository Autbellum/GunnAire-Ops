#!/bin/zsh
# Release half of the 2026091617 ship: push main (Render deploys from main) and
# upload the already-built archive to TestFlight. The bump, commit and archive
# were done locally; this is the part that reaches production.
set -euo pipefail
cd /Users/gunnaire/Projects/GunnAire-Ops
KEY=(-allowProvisioningUpdates -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_7YBP3GY874.p8 -authenticationKeyID 7YBP3GY874 -authenticationKeyIssuerID 08292696-bd8c-4732-9976-2ad43c1a39aa)
OUT=/var/folders/6t/lzhbzk216q3d5mbvsys_lbww0000gp/T/ship-2026091617

[ -d "$OUT/GunnAireOps-2026091617.xcarchive" ] || { echo "archive missing; build it first"; exit 1; }
# Render deploys from main. When the pull request was merged on GitHub, main
# already carries this build and the local ref is behind, which git rejects as
# a non-fast-forward; fast-forward it first, then push what is left (a no-op in
# the merged case). A genuine divergence stops the release.
git fetch origin main:main
git push origin main

xcodebuild -exportArchive -archivePath "$OUT/GunnAireOps-2026091617.xcarchive" \
  -exportOptionsPlist TestFlightExportOptions.plist -exportPath "$OUT/export" "${KEY[@]}" \
  > "$OUT/export.log" 2>&1
grep -E "EXPORT SUCCEEDED|EXPORT FAILED|Upload succeeded|error:" "$OUT/export.log" | tail -4
