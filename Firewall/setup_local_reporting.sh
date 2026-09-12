#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVE_JSON=""
OUTPUT_DIR="$HOME/Library/Logs/GunnAireFirewall"
INSTALL_AGENT=0
RUN_ONCE=1

usage() {
  cat <<'EOF'
Usage: setup_local_reporting.sh --eve-json PATH [options]

  --eve-json PATH          Read-only Suricata eve.json/JSON-lines source
  --output-dir PATH        Report directory (default: ~/Library/Logs/GunnAireFirewall)
  --install-launch-agent  Install a daily 6:30 AM user LaunchAgent
  --no-run-once           Do not create the first deterministic report
  -h, --help              Show this help

The script copies only the deterministic reporting parser. It does not call an AI,
change OPNsense, alter Suricata policy, or modify the source log.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --eve-json) [[ $# -ge 2 ]] || { echo "--eve-json needs a path" >&2; exit 2; }; EVE_JSON="$2"; shift 2 ;;
    --output-dir) [[ $# -ge 2 ]] || { echo "--output-dir needs a path" >&2; exit 2; }; OUTPUT_DIR="$2"; shift 2 ;;
    --install-launch-agent) INSTALL_AGENT=1; shift ;;
    --no-run-once) RUN_ONCE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$EVE_JSON" ]] || { echo "--eve-json is required" >&2; exit 2; }
[[ "$(uname -s)" == "Darwin" ]] || { echo "This installer is for macOS." >&2; exit 2; }
for command in python3 launchctl; do
  command -v "$command" >/dev/null 2>&1 || { echo "$command is required." >&2; exit 2; }
done
PYTHON_BIN="$(command -v python3)"
EVE_JSON="$($PYTHON_BIN -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=True))' "$EVE_JSON")"
[[ -f "$EVE_JSON" && -r "$EVE_JSON" ]] || { echo "EVE source must be a readable file: $EVE_JSON" >&2; exit 2; }
OUTPUT_DIR="$($PYTHON_BIN -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' "$OUTPUT_DIR")"

APP_SUPPORT="$HOME/Library/Application Support/GunnAireFirewall"
LAUNCH_DIR="$HOME/Library/LaunchAgents"
LAUNCH_PATH="$LAUNCH_DIR/com.gunnaire.suricata.report.plist"
REPORT_SCRIPT="$APP_SUPPORT/suricata_report.py"
JSON_OUTPUT="$OUTPUT_DIR/daily.json"
MARKDOWN_OUTPUT="$OUTPUT_DIR/daily.md"
STDOUT="$OUTPUT_DIR/launchd.stdout.log"
STDERR="$OUTPUT_DIR/launchd.stderr.log"
KEY_FILE="$APP_SUPPORT/address-pseudonymization.key"

# Validate all destinations, including hard links, before creating anything.
"$PYTHON_BIN" - "$EVE_JSON" "$REPORT_SCRIPT" "$JSON_OUTPUT" "$MARKDOWN_OUTPUT" "$STDOUT" "$STDERR" "$LAUNCH_PATH" "$KEY_FILE" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).resolve(strict=True)
targets = [pathlib.Path(p).expanduser().resolve() for p in sys.argv[2:]]
if len(set(targets)) != len(targets) or any(p == source or (p.exists() and p.samefile(source)) for p in targets):
    raise SystemExit('Source/output collision; nothing installed')
PY

install -d -m 700 "$APP_SUPPORT" "$OUTPUT_DIR"
"$PYTHON_BIN" - "$KEY_FILE" <<'PY'
import os, pathlib, secrets, stat, sys
p = pathlib.Path(sys.argv[1])
try:
    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
except FileExistsError:
    if p.is_symlink() or not p.is_file() or stat.S_IMODE(p.stat().st_mode) != 0o600 or len(p.read_text().strip()) != 64:
        raise SystemExit('Existing pseudonymization key is invalid or not private')
else:
    with os.fdopen(fd, 'w') as f:
        f.write(secrets.token_hex(32) + '\n')
PY
install -m 700 "$SCRIPT_DIR/suricata_report.py" "$REPORT_SCRIPT"

if (( RUN_ONCE == 1 )); then
  report_status=0
  "$PYTHON_BIN" "$REPORT_SCRIPT" \
    --input "$EVE_JSON" \
    --json-output "$JSON_OUTPUT" \
    --markdown-output "$MARKDOWN_OUTPUT" \
    --anonymize-public-ips --anonymization-key-file "$KEY_FILE" || report_status=$?
  if (( report_status == 1 )) && [[ -s "$JSON_OUTPUT" ]]; then
    echo "Warning: initial report contains malformed log records; scheduling will continue." >&2
  elif (( report_status != 0 )); then
    exit "$report_status"
  fi
fi

if (( INSTALL_AGENT == 1 )); then
  install -d -m 700 "$LAUNCH_DIR"
  "$PYTHON_BIN" - "$LAUNCH_PATH" "$PYTHON_BIN" "$REPORT_SCRIPT" "$EVE_JSON" "$JSON_OUTPUT" "$MARKDOWN_OUTPUT" "$STDOUT" "$STDERR" "$KEY_FILE" <<'PY'
import pathlib, plistlib, sys
path, python, script, source, json_output, markdown_output, stdout, stderr, key_file = sys.argv[1:]
value = {
    "Label": "com.gunnaire.suricata.report",
    "ProgramArguments": [
        python, script,
        "--input", source,
        "--json-output", json_output,
        "--markdown-output", markdown_output,
        "--anonymize-public-ips",
        "--anonymization-key-file", key_file,
    ],
    "StartCalendarInterval": {"Hour": 6, "Minute": 30},
    "ProcessType": "Background",
    "StandardOutPath": stdout,
    "StandardErrorPath": stderr,
}
with pathlib.Path(path).open("wb") as handle:
    plistlib.dump(value, handle, fmt=plistlib.FMT_XML, sort_keys=True)
pathlib.Path(path).chmod(0o600)
PY
  plutil -lint "$LAUNCH_PATH"
  launchctl bootout "gui/$(id -u)" "$LAUNCH_PATH" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$LAUNCH_PATH"
fi

echo "Deterministic Suricata reporting prepared."
echo "Report directory: $OUTPUT_DIR"
if (( INSTALL_AGENT == 1 )); then
  echo "LaunchAgent: $LAUNCH_PATH"
fi
exit 0
