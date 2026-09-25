#!/bin/bash
# Builds "HVAC Design Suite.app" from the SwiftPM executable.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --product HVACDesignSuite
APP="dist/HVAC Design Suite.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/HVACDesignSuite "$APP/Contents/MacOS/HVAC Design Suite"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>HVAC Design Suite</string>
    <key>CFBundleDisplayName</key><string>HVAC Design Suite</string>
    <key>CFBundleIdentifier</key><string>com.gunnaire.hvacdesignsuite</string>
    <key>CFBundleExecutable</key><string>HVAC Design Suite</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>UTExportedTypeDeclarations</key>
    <array><dict>
        <key>UTTypeIdentifier</key><string>com.gunnaire.hvacdesignsuite.project</string>
        <key>UTTypeDescription</key><string>HVAC Design Project</string>
        <key>UTTypeConformsTo</key><array><string>public.json</string></array>
        <key>UTTypeTagSpecification</key>
        <dict><key>public.filename-extension</key><array><string>hvacproj</string></array></dict>
    </dict></array>
    <key>CFBundleDocumentTypes</key>
    <array><dict>
        <key>CFBundleTypeName</key><string>HVAC Design Project</string>
        <key>CFBundleTypeRole</key><string>Editor</string>
        <key>LSHandlerRank</key><string>Owner</string>
        <key>LSItemContentTypes</key><array><string>com.gunnaire.hvacdesignsuite.project</string></array>
    </dict></array>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "Built $APP"
