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

The script never exposes Ollama to the LAN, requests production credentials, or
changes a production service. It writes to the user's Application Support, Logs,
and optionally LaunchAgents folders.
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

[[ "$(uname -s)" == "Darwin" ]] || { echo "This installer is intended for macOS." >&2; exit 2; }
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Warning: this plan was sized for Apple silicon; detected $(uname -m)." >&2
fi

for command in python3 ollama; do
  command -v "$command" >/dev/null 2>&1 || { echo "$command is required and was not found on PATH." >&2; exit 2; }
done
PYTHON_BIN="$(command -v python3)"

version_text="$(ollama --version 2>&1 || true)"
version="$(printf '%s' "$version_text" | sed -E 's/[^0-9]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/' | head -1)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Unable to parse Ollama version: $version_text" >&2; exit 2; }
"$PYTHON_BIN" - "$version" <<'PY'
import sys

def parsed(value: str) -> tuple[int, ...]:
    return tuple(int(part) for part in value.split('.'))

if parsed(sys.argv[1]) < parsed('0.13.3'):
    raise SystemExit(f'Ollama {sys.argv[1]} is too old; 0.13.3 or newer is required.')
PY

# Refuse sessions explicitly configured to expose Ollama beyond loopback.
if [[ -n "${OLLAMA_HOST:-}" ]]; then
  case "$OLLAMA_HOST" in
    127.0.0.1:*|localhost:*|http://127.0.0.1:*|http://localhost:*|\[::1\]:*|http://\[::1\]:*) ;;
    *) echo "Refusing non-loopback OLLAMA_HOST: $OLLAMA_HOST" >&2; exit 2 ;;
  esac
fi

if ! /usr/bin/curl --silent --fail --max-time 3 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
  if [[ -d /Applications/Ollama.app ]]; then
    /usr/bin/open -gja Ollama
    for _ in {1..20}; do
      sleep 1
      /usr/bin/curl --silent --fail --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && break
    done
  fi
fi
/usr/bin/curl --silent --fail --max-time 3 http://127.0.0.1:11434/api/tags >/dev/null \
  || { echo "Ollama is not responding on loopback port 11434." >&2; exit 2; }

# Verify the running listener, not just this shell's OLLAMA_HOST setting.
"$PYTHON_BIN" - <<'PY'
import subprocess
result = subprocess.run(['/usr/sbin/lsof', '-nP', '-iTCP:11434', '-sTCP:LISTEN', '-Fn'],
                        capture_output=True, text=True, check=False)
listeners = [line[1:] for line in result.stdout.splitlines() if line.startswith('n')]
if result.returncode or not listeners or any(value not in ('127.0.0.1:11434', '[::1]:11434') for value in listeners):
    raise SystemExit('Cannot verify an exclusively loopback Ollama listener; installation stopped.')
PY

required_gib=42
[[ "$INSTALL_MODE" == "all" ]] && required_gib=66
model_storage="${OLLAMA_MODELS:-$HOME/.ollama/models}"
[[ -d "$model_storage" ]] || model_storage="$HOME/.ollama"
available_kib="$(df -Pk "$model_storage" | awk 'NR==2 {print $4}')"
available_gib=$(( available_kib / 1024 / 1024 ))
(( available_gib >= required_gib )) || {
  echo "Insufficient free space: ${available_gib} GiB available; ${required_gib} GiB required with safety margin." >&2
  exit 2
}

mkdir -p "$APP_SUPPORT/bin" "$APP_SUPPORT/config" "$LOG_ROOT/runs"
for file in models.json policy.json suites.json benchmark_cases.json; do
  cp "$SCRIPT_DIR/config/$file" "$APP_SUPPORT/config/$file"
done
for file in local_ai.py qa_runner.py benchmark.py; do
  cp "$SCRIPT_DIR/$file" "$APP_SUPPORT/$file"
done

models=("devstral-small-2:24b" "gpt-oss:20b")
if [[ "$INSTALL_MODE" == "all" ]]; then
  models+=("qwen3-coder:30b" "qwen2.5-coder:7b")
fi
for model in "${models[@]}"; do
  safe_name="${model//[:\//]/_}"
  echo "Pulling $model"
  ollama pull "$model" 2>&1 | tee "$LOG_ROOT/pull-${safe_name}.log"
done

cat > "$APP_SUPPORT/bin/codex-local" <<'EOF'
#!/bin/bash
set -euo pipefail
# Compatibility name only: requests must pass the same redaction and file guards.
# For autonomous edits use the separately sandboxed local worker, not direct Codex.
exec "$HOME/Library/Application Support/GunnAireLocalAI/bin/gunnaire-local-ai" ask --role coder "$@"
EOF
chmod 700 "$APP_SUPPORT/bin/codex-local"

cat > "$APP_SUPPORT/bin/gunnaire-local-ai" <<EOF
#!/bin/bash
set -euo pipefail
exec "$PYTHON_BIN" "$APP_SUPPORT/local_ai.py" \\
  --models "$APP_SUPPORT/config/models.json" \\
  --policy "$APP_SUPPORT/config/policy.json" "\$@"
EOF
chmod 700 "$APP_SUPPORT/bin/gunnaire-local-ai"

cat > "$APP_SUPPORT/bin/gunnaire-local-qa" <<EOF
#!/bin/bash
set -euo pipefail
exec "$PYTHON_BIN" "$APP_SUPPORT/qa_runner.py" \\
  --models "$APP_SUPPORT/config/models.json" \\
  --policy "$APP_SUPPORT/config/policy.json" \\
  --suites "$APP_SUPPORT/config/suites.json" "\$@"
EOF
chmod 700 "$APP_SUPPORT/bin/gunnaire-local-qa"

PYTHONDONTWRITEBYTECODE=1 "$PYTHON_BIN" -m unittest discover -s "$SCRIPT_DIR/tests" -p 'test_*.py' -v
"$PYTHON_BIN" "$SCRIPT_DIR/local_ai.py" doctor --output "$LOG_ROOT/doctor-latest.json"

if (( RUN_BENCHMARK == 1 )); then
  roles=(coder reviewer)
  [[ "$INSTALL_MODE" == "all" ]] && roles+=(challenger)
  "$PYTHON_BIN" "$SCRIPT_DIR/benchmark.py" --roles "${roles[@]}" --output "$LOG_ROOT/benchmark-latest.json"
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

"$PYTHON_BIN" - "$LOG_ROOT/setup-status.json" "$REPO" "$INSTALL_MODE" "$RUN_BENCHMARK" "$INSTALL_LAUNCH_AGENT" "$version" <<'PY'
import json, pathlib, sys
path, repo, mode, benchmark, agent, version = sys.argv[1:]
payload = {
    'status': 'completed',
    'repository': repo,
    'install_mode': mode,
    'benchmark_requested': benchmark == '1',
    'launch_agent_requested': agent == '1',
    'ollama_version': version,
    'endpoint': 'http://127.0.0.1:11434',
    'note': 'No production deployment or network change was performed.'
}
pathlib.Path(path).write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')
PY

echo "Local AI setup completed."
echo "Doctor report: $LOG_ROOT/doctor-latest.json"
(( RUN_BENCHMARK == 1 )) && echo "Benchmark report: $LOG_ROOT/benchmark-latest.json"
echo "Guarded Codex launcher: $APP_SUPPORT/bin/codex-local"
