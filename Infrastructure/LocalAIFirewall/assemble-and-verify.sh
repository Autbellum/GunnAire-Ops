#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE_NAME="GunnAire_Local_AI_Firewall_v1.0.0.tar.xz"
EXPECTED_SHA256="64004d3e6ea8a87e3acdfc522f3e596f392f094012a5fb9eb8c8dc74f6fa60db"
EXPECTED_ROOT="GunnAire_Local_AI_Firewall_v1.0.0"

workspace="$(mktemp -d "${TMPDIR:-/tmp}/gunnaire-local-ai-firewall.XXXXXX")"
cleanup() {
  rm -rf "$workspace"
}
trap cleanup EXIT

mapfile_supported=0
if help mapfile >/dev/null 2>&1; then
  mapfile_supported=1
fi

if (( mapfile_supported == 1 )); then
  mapfile -t parts < <(find "$SCRIPT_DIR" -maxdepth 1 -type f -name "${ARCHIVE_NAME}.part-*" -print | LC_ALL=C sort)
else
  parts=()
  while IFS= read -r part; do
    parts+=("$part")
  done < <(find "$SCRIPT_DIR" -maxdepth 1 -type f -name "${ARCHIVE_NAME}.part-*" -print | LC_ALL=C sort)
fi

if [[ "${#parts[@]}" -ne 6 ]]; then
  echo "Expected exactly 6 archive parts; found ${#parts[@]}." >&2
  exit 2
fi

archive="$workspace/$ARCHIVE_NAME"
cat "${parts[@]}" > "$archive"

actual_sha256="$(shasum -a 256 "$archive" | awk '{print $1}')"
if [[ "$actual_sha256" != "$EXPECTED_SHA256" ]]; then
  echo "Archive checksum mismatch." >&2
  echo "Expected: $EXPECTED_SHA256" >&2
  echo "Actual:   $actual_sha256" >&2
  exit 1
fi

mkdir -p "$workspace/extracted"
tar -xJf "$archive" -C "$workspace/extracted"
package_root="$workspace/extracted/$EXPECTED_ROOT"

if [[ ! -d "$package_root" ]]; then
  echo "Expected extracted package root not found: $package_root" >&2
  exit 1
fi

if [[ ! -f "$package_root/Makefile" || ! -f "$package_root/Verification/verification.json" ]]; then
  echo "Extracted package is missing required verification files." >&2
  exit 1
fi

make -C "$package_root" verify

python3 - "$package_root/Verification/verification.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
assert data["status"] == "pass", data
assert data["deterministic_unit_tests"]["total"] == {
    "passed": 33,
    "failed": 0,
    "skipped": 0,
}, data
assert data["firewall_static_validation"] == {
    "status": "pass",
    "errors": 0,
    "warnings": 0,
    "deployed": False,
}, data
assert data["guarded_qa_runner"]["ai_called"] is False, data
assert data["live_mac_model_installation_verified"] is False, data
assert data["live_firewall_deployment_verified"] is False, data
print("Verification manifest assertions: PASS")
PY

echo "Archive SHA-256: $actual_sha256"
echo "GunnAire Local AI and Firewall Kit v1.0.0: PASS"
