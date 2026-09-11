#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_SUPPORT="$HOME/Library/Application Support/GunnAireLocalAI"
LOG_ROOT="$HOME/Library/Logs/GunnAireLocalAI"
REPO=""
INSTALL_MODE="core"
RUN_BENCHMARK=0
INSTALL_LAUNCH_AGENT=0

usage() {
  cat <<'EOF'
Usage: setup_local_ai.sh --repo PATH [options]

Options:
  --install-core           Pull Devstral Small 2 and gpt-oss 20B (default)
  --install-all            Also pull Qwen3-Coder 30B and Qwen 2.5 Coder 7B
  --run-benchmark          Run the guarded local benchmark after installation
  --install-launch-agent   Install a daily user-level health check
  --repo PATH              GunnAire repository root
  -h, --help               Show help

The script never exposes Ollama to the LAN, requests credentials, or changes a
production service. It writes only to the user's Application Support/Logs folders
and, when requested, the user's LaunchAgents folder.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-core) INSTALL_MODE="core"; shift ;;
    --install-all) INSTALL_MODE="all"; shift ;;
    --run-benchmark) RUN_BENCHMARK=1; shift ;;
    --install-launch-agent) INSTALL_LAUNCH_AGENT=1; shift ;;
    --repo)
      [[ $# -ge 2 ]] || { echo "--repo requires a path" >&2; exit 2; }
      REPO="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$REPO" ]] || { echo "--repo is required" >&2; exit 2; }
REPO="$(cd "$REPO" && pwd)"
[[ -d "$REPO" ]] || { echo "Repository not found: $REPO" >&2; exit 2; }

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer is intended for macOS." >&2
  exit 2
fi
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Warning: this plan was sized for Apple silicon; detected $(uname -m)." >&2
fi

mkdir -p "$APP_SUPPORT/bin" "$APP_SUPPORT/config" "$LOG_ROOT/runs"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required." >&2
  exit 2
fi
PYTHON_BIN="$(command -v python3)"
if ! command -v codex >/dev/null 2>&1; then
  echo "Codex CLI is required to create the guarded local Codex launcher." >&2
  exit 2
fi
if ! command -v ollama >/dev/null 2>&1; then
  echo "Ollama is not installed or not on PATH. Install the current official Ollama release first." >&2
  exit 2
fi

# Devstral Small 2 currently requires Ollama 0.13.3 or later.
version_text="$(ollama --version 2>&1 || true)"
version="$(printf '%s' "$version_text" | sed -E 's/[^0-9]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/' | head -1)"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Unable to parse Ollama version from: $version_text" >&2
  exit 2
fi
python3 - "$version" <<'PY'
import sys
from itertools import zip_longest

def parse(value):
    return tuple(int(part) for part in value.split('.'))

installed = parse(sys.argv[1])
required = parse('0.13.3')
if installed < required:
    raise SystemExit(f'Ollama {sys.argv[1]} is too old; 0.13.3 or newer is required.')
PY

# Do not permit an installer session that intentionally binds Ollama to a non-loopback address.
if [[ -n "${OLLAMA_HOST:-}" ]]; then
  case "$OLLAMA_HOST" in
    127.0.0.1:*|localhost:*|http://127.0.0.1:*|http://localhost:*|\[::1\]:*|http://\[::1\]:*) ;;
    *) echo "Refusing because OLLAMA_HOST is not loopback-only: $OLLAMA_HOST" >&2; exit 2 ;;
  esac
fi

if ! /usr/bin/curl --silent --fail --max-time 3 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
  if [[ -d /Applications/Ollama.app ]]; then
    /usr/bin/open -gja Ollama
    for _ in {1..20}; do
      sleep 1
      if /usr/bin/curl --silent --fail --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
        break
      fi
    done
  fi
fi
/usr/bin/curl --silent --fail --max-time 3 http://127.0.0.1:11434/api/tags >/dev/null \
  || { echo "Ollama is not responding on loopback port 11434." >&2; exit 2; }

required_gib=42
if [[ "$INSTALL_MODE" == "all" ]]; then
  required_gib=66
fi
available_kib="$(df -Pk "$HOME" | awk 'NR==2 {print $4}')"
available_gib=$(( available_kib / 1024 / 1024 ))
if (( available_gib < required_gib )); then
  echo "Insufficient free space: ${available_gib} GiB available; ${required_gib} GiB required with safety margin." >&2
  exit 2
fi

cp "$SCRIPT_DIR/config/models.json" "$APP_SUPPORT/config/models.json"
cp "$SCRIPT_DIR/config/policy.json" "$APP_SUPPORT/config/policy.json"
cp "$SCRIPT_DIR/config/suites.json" "$APP_SUPPORT/config/suites.json"
cp "$SCRIPT_DIR/config/benchmark_cases.json" "$APP_SUPPORT/config/benchmark_cases.json"
cp "$SCRIPT_DIR/local_ai.py" "$APP_SUPPORT/local_ai.py"
cp "$SCRIPT_DIR/qa_runner.py" "$APP_SUPPORT/qa_runner.py"
cp "$SCRIPT_DIR/benchmark.py" "$APP_SUPPORT/benchmark.py"

models=("devstral-small-2:24b" "gpt-oss:20b")
if [[ "$INSTALL_MODE" == "all" ]]; then
  models+=("qwen3-coder:30b" "qwen2.5-coder:7b")
fi

for model in "${models[@]}"; do
  safe_name="${model//[:\/]/_}"
  echo "Pulling $model"
  ollama pull "$model" 2>&1 | tee "$LOG_ROOT/pull-${safe_name}.log"
done

cat > "$APP_SUPPORT/bin/codex-local" <<'EOF'
#!/bin/bash
set -euo pipefail
workspace="${1:-$PWD}"
if [[ $# -gt 0 ]]; then shift; fi
exec codex --oss --local-provider ollama --model devstral-small-2:24b \
  --sandbox read-only --ask-for-approval on-request --cd "$workspace" "$@"
EOF
chmod 700 "$APP_SUPPORT/bin/codex-local"

cat > "$APP_SUPPORT/bin/gunnaire-local-ai" <<EOF
#!/bin/bash
set -euo pipefail
exec "$PYTHON_BIN" "$APP_SUPPORT/local_ai.py" \
  --models "$APP_SUPPORT/config/models.json" \
  --policy "$APP_SUPPORT/config/policy.json" "\$@"
EOF
chmod 700 "$APP_SUPPORT/bin/gunnaire-local-ai"

cat > "$APP_SUPPORT/bin/gunnaire-local-qa" <<EOF
#!/bin/bash
set -euo pipefail
exec "$PYTHON_BIN" "$APP_SUPPORT/qa_runner.py" \
  --models "$APP_SUPPORT/config/models.json" \
  --policy "$APP_SUPPORT/config/policy.json" \
  --suites "$APP_SUPPORT/config/suites.json" "\$@"
EOF
chmod 700 "$APP_SUPPORT/bin/gunnaire-local-qa"

python3 -m unittest discover -s "$SCRIPT_DIR/tests" -p 'test_*.py' -v
python3 "$SCRIPT_DIR/local_ai.py" doctor --output "$LOG_ROOT/doctor-latest.json"

if (( RUN_BENCHMARK == 1 )); then
  roles=(coder reviewer)
  if [[ "$INSTALL_MODE" == "all" ]]; then roles+=(challenger); fi
  python3 "$SCRIPT_DIR/benchmark.py" --roles "${roles[@]}" --output "$LOG_ROOT/benchmark-latest.json"
fi

if (( INSTALL_LAUNCH_AGENT == 1 )); then
  launch_dir="$HOME/Library/LaunchAgents"
  launch_path="$launch_dir/com.gunnaire.localai.health.plist"
  mkdir -p "$launch_dir"
  sed \
    -e "s|__PYTHON__|$PYTHON_BIN|g" \
    -e "s|__LOCAL_AI__|$APP_SUPPORT/local_ai.py|g" \
    -e "s|__MODELS__|$APP_SUPPORT/config/models.json|g" \
    -e "s|__POLICY__|$APP_SUPPORT/config/policy.json|g" \
    -e "s|__OUTPUT__|$LOG_ROOT/doctor-scheduled.json|g" \
    -e "s|__STDOUT__|$LOG_ROOT/launchd-health.stdout.log|g" \
    -e "s|__STDERR__|$LOG_ROOT/launchd-health.stderr.log|g" \
    "$SCRIPT_DIR/launchd/com.gunnaire.localai.health.plist.template" > "$launch_path"
  plutil -lint "$launch_path"
  launchctl bootout "gui/$(id -u)" "$launch_path" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$launch_path"
fi

cat > "$LOG_ROOT/setup-status.json" <<EOF
{
  "status": "completed",
  "repository": $(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$REPO"),
  "install_mode": "$INSTALL_MODE",
  "benchmark_requested": $RUN_BENCHMARK,
  "launch_agent_requested": $INSTALL_LAUNCH_AGENT,
  "ollama_version": "$version",
  "endpoint": "http://127.0.0.1:11434",
  "note": "No production deployment or network change was performed."
}
EOF

echo "Local AI setup completed."
echo "Doctor report: $LOG_ROOT/doctor-latest.json"
if (( RUN_BENCHMARK == 1 )); then echo "Benchmark report: $LOG_ROOT/benchmark-latest.json"; fi
echo "Guarded Codex launcher: $APP_SUPPORT/bin/codex-local"
