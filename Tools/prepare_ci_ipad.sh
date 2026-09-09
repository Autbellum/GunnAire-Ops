#!/bin/bash
# Create a job-owned simulator; never erase or retarget an existing device.
set -euo pipefail

: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"
if [[ "${CI_SHARD:-}" != "0" && "${CI_SHARD:-}" != "1" ]]; then
  echo "::error::Unknown iPad test shard."
  exit 64
fi

runtime_id="com.apple.CoreSimulator.SimRuntime.iOS-26-2"
device_type="com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB"
evidence="$RUNNER_TEMP/native-results"
mkdir -p "$evidence"
xcrun simctl list -j > "$evidence/simulators-before.json"

# A missing runtime is an environment failure, not permission to choose a newer OS.
if ! jq -e --arg runtime "$runtime_id" --arg device "$device_type" '
  ([.runtimes[] | select(.identifier == $runtime and .isAvailable == true)] | length) == 1
  and ([.devicetypes[] | select(.identifier == $device)] | length) == 1
' "$evidence/simulators-before.json" > /dev/null; then
  echo "::error::Required iOS 26.2 runtime or 13-inch M5 iPad device type is unavailable. See simulator inventory."
  exit 70
fi

simulator_id="$(xcrun simctl create "GunnAire CI iPad $CI_SHARD" "$device_type" "$runtime_id")"
if [[ ! "$simulator_id" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
  echo "::error::Simulator creation did not return one valid device identifier."
  exit 70
fi
xcrun simctl boot "$simulator_id" 2>&1 | tee "$evidence/simulator-boot.log"
xcrun simctl bootstatus "$simulator_id" -b 2>&1 | tee -a "$evidence/simulator-boot.log"
xcrun simctl list -j > "$evidence/simulators-ready.json"
jq -e --arg runtime "$runtime_id" --arg device "$device_type" --arg udid "$simulator_id" '
  [.devices[$runtime][] | select(.udid == $udid and .deviceTypeIdentifier == $device
    and .isAvailable == true and .state == "Booted")] | length == 1
' "$evidence/simulators-ready.json" > /dev/null

# Export only a fully booted, exact-model/exact-runtime device to the test step.
printf 'CI_IPAD_UDID=%s\n' "$simulator_id" >> "$GITHUB_ENV"
