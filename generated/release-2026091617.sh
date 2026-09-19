#!/bin/zsh
# Release half of the 2026091617 ship: push main (Render deploys from main) and
# upload the already-built archive to TestFlight. The bump, commit and archive
# were done locally; this is the part that reaches production.
set -eu
cd /Users/gunnaire/Projects/GunnAire-Ops
KEY=(-allowProvisioningUpdates -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_7YBP3GY874.p8 -authenticationKeyID 7YBP3GY874 -authenticationKeyIssuerID 08292696-bd8c-4732-9976-2ad43c1a39aa)
OUT=/var/folders/6t/lzhbzk216q3d5mbvsys_lbww0000gp/T/ship-2026091617

[ -d "$OUT/GunnAireOps-2026091617.xcarchive" ] || { echo "archive missing; build it first"; exit 1; }
git push origin main 2>&1 | tail -1

xcodebuild -exportArchive -archivePath "$OUT/GunnAireOps-2026091617.xcarchive" \
  -exportOptionsPlist TestFlightExportOptions.plist -exportPath "$OUT/export" "${KEY[@]}" \
  > "$OUT/export.log" 2>&1
grep -E "EXPORT SUCCEEDED|EXPORT FAILED|Upload succeeded|error:" "$OUT/export.log" | tail -4
