#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_SUPPORT="$HOME/Library/Application Support/GunnAireLocalAI"
LOG_ROOT="$HOME/Library/Logs/GunnAireLocalAI"
REPO=""
INSTALL_MODE="core"
RUN_BENCHMARK=0
INSTALL_AGENT=0

usage() {
  cat <<'EOF'
Usage: setup_local_ai.sh --repo PATH [options]

  --install-core          Pull Devstral Small 2 and gpt-oss 20B (default)
  --install-all           Also pull Qwen3-Coder 30B and Qwen 2.5 Coder 7B
  --run-benchmark         Run the local benchmark after installation
  --install-launch-agent Install a daily user-level health check
  --repo PATH             GunnAire repository root
  -h, --help              Show this help

This installer does not expose Ollama to the LAN, request production credentials,
or change a firewall, router, NAS, provider account, source branch, or deployment.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-core) INSTALL_MODE="core"; shift ;;
    --install-all) INSTALL_MODE="all"; shift ;;
    --run-benchmark) RUN_BENCHMARK=1; shift ;;
    --install-launch-agent) INSTALL_AGENT=1; shift ;;
    --repo) [[ $# -ge 2 ]] || { echo "--repo needs a path" >&2; exit 2; }; REPO="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$REPO" ]] || { echo "--repo is required" >&2; exit 2; }
REPO="$(cd "$REPO" && pwd)"
[[ "$(uname -s)" == "Darwin" ]] || { echo "This installer is for macOS." >&2; exit 2; }
[[ -d "$REPO" ]] || { echo "Repository not found: $REPO" >&2; exit 2; }

for command in python3 ollama codex curl; do
  command -v "$command" >/dev/null 2>&1 || { echo "$command is required." >&2; exit 2; }
done
PYTHON_BIN="$(command -v python3)"

version_text="$(ollama --version 2>&1 || true)"
version="$(printf '%s' "$version_text" | sed -E 's/[^0-9]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/' | head -1)"
"$PYTHON_BIN" - "$version" <<'PY'
import sys

def v(text):
    try:
        return tuple(int(part) for part in text.split('.'))
    except Exception as exc:
        raise SystemExit(f"Cannot parse Ollama version {text!r}: {exc}")

if v(sys.argv[1]) < v("0.13.3"):
    raise SystemExit(f"Ollama {sys.argv[1]} is too old; 0.13.3 or newer is required.")
PY

if [[ -n "${OLLAMA_HOST:-}" ]]; then
  case "$OLLAMA_HOST" in
    127.0.0.1:*|localhost:*|http://127.0.0.1:*|http://localhost:*|\[::1\]:*|http://\[::1\]:*) ;;
    *) echo "Refusing non-loopback OLLAMA_HOST: $OLLAMA_HOST" >&2; exit 2 ;;
  esac
fi

if ! curl --silent --fail --max-time 3 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
  if [[ -d /Applications/Ollama.app ]]; then
    open -gja Ollama
    for _ in {1..20}; do
      sleep 1
      curl --silent --fail --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && break
    done
  fi
fi
curl --silent --fail --max-time 3 http://127.0.0.1:11434/api/tags >/dev/null \
  || { echo "Ollama is not responding on loopback port 11434." >&2; exit 2; }

# A successful loopback request does not prove the service is not also listening
# on every LAN interface. Refuse installation when lsof reports a non-loopback
# listener so model prompts and repository context are not exposed to the network.
if command -v lsof >/dev/null 2>&1; then
  listener_lines="$(lsof -nP -iTCP:11434 -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 {print $(NF-1)}')"
  [[ -n "$listener_lines" ]] \
    || { echo "Unable to verify the Ollama listener address with lsof." >&2; exit 2; }
  while IFS= read -r listener; do
    [[ -z "$listener" ]] && continue
    case "$listener" in
      127.*:11434|\[::1\]:11434|localhost:11434) ;;
      *) echo "Refusing Ollama listener outside loopback: $listener" >&2; exit 2 ;;
    esac
  done <<< "$listener_lines"
else
  echo "lsof is required to verify that Ollama is not exposed to the LAN." >&2
  exit 2
fi

required_gib=42
[[ "$INSTALL_MODE" == "all" ]] && required_gib=66
available_kib="$(df -Pk "$HOME" | awk 'NR==2 {print $4}')"
available_gib=$(( available_kib / 1024 / 1024 ))
(( available_gib >= required_gib )) \
  || { echo "Need ${required_gib} GiB free with safety margin; ${available_gib} GiB available." >&2; exit 2; }

mkdir -p "$APP_SUPPORT/bin" "$APP_SUPPORT/config" "$LOG_ROOT/runs"
cp "$SCRIPT_DIR"/config/*.json "$APP_SUPPORT/config/"
cp "$SCRIPT_DIR"/{local_ai.py,qa_runner.py,benchmark.py} "$APP_SUPPORT/"

models=("devstral-small-2:24b" "gpt-oss:20b")
[[ "$INSTALL_MODE" == "all" ]] && models+=("qwen3-coder:30b" "qwen2.5-coder:7b")
for model in "${models[@]}"; do
  safe="$(printf '%s' "$model" | tr ':/' '__')"
  echo "Pulling $model"
  ollama pull "$model" 2>&1 | tee "$LOG_ROOT/pull-${safe}.log"
done

cat > "$APP_SUPPORT/bin/codex-local-review" <<'EOF'
#!/bin/bash
set -euo pipefail
workspace="${1:-$PWD}"
[[ $# -gt 0 ]] && shift
exec codex --oss --local-provider ollama --model devstral-small-2:24b \
  --sandbox read-only --ask-for-approval on-request --cd "$workspace" "$@"
EOF
chmod 700 "$APP_SUPPORT/bin/codex-local-review"

cat > "$APP_SUPPORT/bin/codex-local-workspace" <<'EOF'
#!/bin/bash
set -euo pipefail
workspace="${1:-$PWD}"
[[ $# -gt 0 ]] && shift
exec codex --oss --local-provider ollama --model devstral-small-2:24b \
  --sandbox workspace-write --ask-for-approval on-request --cd "$workspace" "$@"
EOF
chmod 700 "$APP_SUPPORT/bin/codex-local-workspace"

cat > "$APP_SUPPORT/bin/codex-local" <<EOF
#!/bin/bash
set -euo pipefail
exec "$APP_SUPPORT/bin/codex-local-review" "\$@"
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

PYTHONDONTWRITEBYTECODE=1 "$PYTHON_BIN" -m unittest discover -s "$SCRIPT_DIR/tests" -p 'test_*.py' -v
"$PYTHON_BIN" "$SCRIPT_DIR/local_ai.py" doctor --output "$LOG_ROOT/doctor-latest.json"

if (( RUN_BENCHMARK == 1 )); then
  roles=(coder reviewer)
  [[ "$INSTALL_MODE" == "all" ]] && roles+=(challenger)
  "$PYTHON_BIN" "$SCRIPT_DIR/benchmark.py" --roles "${roles[@]}" --output "$LOG_ROOT/benchmark-latest.json"
fi

if (( INSTALL_AGENT == 1 )); then
  launch_dir="$HOME/Library/LaunchAgents"
  launch_path="$launch_dir/com.gunnaire.localai.health.plist"
  mkdir -p "$launch_dir"
  sed \
    -e "s|__PYTHON__|$PYTHON_BIN|g" \
    -e "s|__LOCAL_AI__|$APP_SUPPORT/local_ai.py|g" \
    -e "s|__MODELS__|$APP_SUPPORT/config/models.json|g" \
    -e "s|__POLICY__|$APP_SUPPORT/config/policy.json|g" \
    -e "s|__OUTPUT__|$LOG_ROOT/doctor-scheduled.json|g" \
    -e "s|__STDOUT__|$LOG_ROOT/health.stdout.log|g" \
    -e "s|__STDERR__|$LOG_ROOT/health.stderr.log|g" \
    "$SCRIPT_DIR/launchd/com.gunnaire.localai.health.plist.template" > "$launch_path"
  plutil -lint "$launch_path"
  launchctl bootout "gui/$(id -u)" "$launch_path" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$launch_path"
fi

"$PYTHON_BIN" - "$LOG_ROOT/setup-status.json" "$REPO" "$INSTALL_MODE" "$RUN_BENCHMARK" "$INSTALL_AGENT" "$version" <<'PY'
import json, pathlib, sys
path, repo, mode, benchmark, agent, version = sys.argv[1:]
pathlib.Path(path).write_text(json.dumps({
    "status": "completed",
    "repository": repo,
    "install_mode": mode,
    "benchmark_requested": benchmark == "1",
    "launch_agent_requested": agent == "1",
    "ollama_version": version,
    "endpoint": "http://127.0.0.1:11434",
    "production_or_network_change_performed": False,
}, indent=2) + "\n")
PY

echo "Local AI setup complete."
echo "Health report: $LOG_ROOT/doctor-latest.json"
echo "Read-only local Codex: $APP_SUPPORT/bin/codex-local-review"
echo "Workspace-write local Codex: $APP_SUPPORT/bin/codex-local-workspace"
