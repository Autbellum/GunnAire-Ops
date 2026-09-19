#!/bin/bash
# capture_freeze.sh - Automated iOS App Boot & Diagnostic Tracker for Claude Code
# Adapted to this repository: there is no .xcworkspace, only the project, and
# the bundle identifier is com.gunnaire.businesssuite.
set -u
cd "$(dirname "$0")/.."
PROJECT_NAME="GunnAire Ops.xcodeproj"
SCHEME_NAME="GunnAire Ops"
BUNDLE_ID="com.gunnaire.businesssuite"
DERIVED="${DERIVED_DATA:-$TMPDIR/capture-freeze-dd}"

echo "🚀 [1/4] Cleaning build artifacts..."
xcodebuild clean -project "$PROJECT_NAME" -scheme "$SCHEME_NAME" -derivedDataPath "$DERIVED" -quiet

echo "⚙️ [2/4] Compiling application in Debug mode..."
xcodebuild build -project "$PROJECT_NAME" -scheme "$SCHEME_NAME" -configuration Debug -sdk iphonesimulator -derivedDataPath "$DERIVED" -quiet
if [ $? -ne 0 ]; then
    echo "❌ Build failed! Checking compiler logs..."
    xcodebuild build -project "$PROJECT_NAME" -scheme "$SCHEME_NAME" -configuration Debug -sdk iphonesimulator -derivedDataPath "$DERIVED" 2>&1 | grep -E "error:|warning:" | sort -u
    exit 1
fi

echo "📱 [3/4] Finding booted or default iOS Simulator..."
DEVICE_ID=$(xcrun simctl list devices | grep "Booted" | head -n 1 | grep -oE '[A-Z0-9]{8}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{12}')
if [ -z "$DEVICE_ID" ]; then
    echo "⚠️ No booted simulator found. Waking up the first available iPad..."
    DEVICE_ID=$(xcrun simctl list devices available | grep "iPad" | head -n 1 | grep -oE '[A-Z0-9]{8}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{12}')
    xcrun simctl boot "$DEVICE_ID"
fi
xcrun simctl bootstatus "$DEVICE_ID" -b >/dev/null 2>&1 || true
echo "Using simulator $DEVICE_ID"

echo "📲 [4/4] Installing and booting app with live log capture..."
APP_PATH=$(xcodebuild -project "$PROJECT_NAME" -scheme "$SCHEME_NAME" -configuration Debug -sdk iphonesimulator -derivedDataPath "$DERIVED" -showBuildSettings 2>/dev/null | grep -E "CODESIGNING_FOLDER_PATH" | awk -F " = " '{print $2}')
xcrun simctl install "$DEVICE_ID" "$APP_PATH"

echo "⏱️ Launching app. Capturing the first 10 seconds of log streams to find main thread stalls..."
xcrun simctl spawn "$DEVICE_ID" log stream --style compact --predicate 'process == "GunnAire Ops" AND (eventMessage CONTAINS[c] "main thread" OR eventMessage CONTAINS[c] "hang" OR eventMessage CONTAINS[c] "blocked" OR eventMessage CONTAINS[c] "Performance event" OR eventMessage CONTAINS[c] "watchdog")' > generated/launch_diagnostic.log 2>&1 &
STREAM_PID=$!
sleep 1
xcrun simctl launch --terminate-running-process "$DEVICE_ID" "$BUNDLE_ID"
sleep 10
kill $STREAM_PID 2>/dev/null
echo "✅ Diagnostic complete! Results written to 'generated/launch_diagnostic.log'."
