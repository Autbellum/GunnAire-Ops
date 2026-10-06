#!/bin/zsh
# Eric's release step: upload the verified, frozen candidate to TestFlight.
# This script does not merge or push main.
set -euo pipefail

OUT=/Users/gunnaire/Documents/GunnAireCompletion/2026-09-21
ARCHIVE="$OUT/GunnAireOps-2026092101.xcarchive"
MANIFEST="$OUT/release-manifest.json"
OPTIONS="$OUT/frozen-source/TestFlightExportOptions.plist"

python3 - "$MANIFEST" "$ARCHIVE" "$OPTIONS" <<'PY'
import hashlib
import json
import plistlib
import subprocess
import sys
from pathlib import Path

manifest_path, archive, options = map(Path, sys.argv[1:])
manifest = json.loads(manifest_path.read_text())
with (archive / 'Info.plist').open('rb') as handle:
    archive_info = plistlib.load(handle)
app = archive / 'Products' / archive_info['ApplicationProperties']['ApplicationPath']
with (app / 'Info.plist').open('rb') as handle:
    app_info = plistlib.load(handle)
if str(app_info['CFBundleVersion']) != '2026092101':
    raise SystemExit('The archive is not build 2026092101.')
if app_info['CFBundleIdentifier'] != 'com.gunnaire.businesssuite':
    raise SystemExit('The archive does not belong to GunnAire Ops.')
binary = app / app_info['CFBundleExecutable']
if hashlib.sha256(binary.read_bytes()).hexdigest() != manifest['archive_binary_sha256']:
    raise SystemExit('The archive differs from the verified release manifest.')
if hashlib.sha256(options.read_bytes()).hexdigest() != manifest['export_options_sha256']:
    raise SystemExit('The export options differ from the verified release manifest.')
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
print('Verified candidate build 2026092101 from commit ' + manifest['source_commit'])
PY

KEY=(-allowProvisioningUpdates
     -authenticationKeyPath /Users/gunnaire/.appstoreconnect/private_keys/AuthKey_7YBP3GY874.p8
     -authenticationKeyID 7YBP3GY874
     -authenticationKeyIssuerID 08292696-bd8c-4732-9976-2ad43c1a39aa)

echo "Uploading build 2026092101. Full output: $OUT/export.log"
if xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$OPTIONS" -exportPath "$OUT/export" "${KEY[@]}" \
    > "$OUT/export.log" 2>&1; then
    echo 'Upload command completed. Verify build 2026092101 processing and tester access in App Store Connect.'
else
    echo "Upload was not confirmed. Review $OUT/export.log before retrying."
    exit 1
fi
