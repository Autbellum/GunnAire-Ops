#!/bin/bash
set -euo pipefail

MODE="core"
case "${1:-}" in
  --install-core|"") MODE="core" ;;
  --install-all) MODE="all" ;;
  -h|--help)
    echo "Usage: $0 [--install-core|--install-all]"
    exit 0 ;;
  *) echo "Unknown option: $1" >&2; exit 2 ;;
esac

[[ "$(uname -s)" == "Darwin" ]] || { echo "macOS is required." >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 is required." >&2; exit 2; }
command -v ollama >/dev/null || { echo "Ollama is required." >&2; exit 2; }
command -v codex >/dev/null || { echo "Codex CLI is required." >&2; exit 2; }

if [[ -n "${OLLAMA_HOST:-}" ]]; then
  case "$OLLAMA_HOST" in
    127.0.0.1:*|localhost:*|http://127.0.0.1:*|http://localhost:*|\[::1\]:*|http://\[::1\]:*) ;;
    *) echo "Refusing non-loopback OLLAMA_HOST: $OLLAMA_HOST" >&2; exit 2 ;;
  esac
fi

version="$(ollama --version 2>&1 | sed -E 's/[^0-9]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/' | head -1)"
python3 - "$version" <<'PY'
import sys
try:
    installed = tuple(int(part) for part in sys.argv[1].split('.'))
except ValueError:
    raise SystemExit('Unable to parse the Ollama version.')
if installed < (0, 13, 3):
    raise SystemExit(f'Ollama {sys.argv[1]} is too old; 0.13.3 or newer is required.')
PY

if ! curl --silent --fail --max-time 3 http://127.0.0.1:11434/api/tags >/dev/null; then
  [[ -d /Applications/Ollama.app ]] && open -gja Ollama
  for _ in {1..20}; do
    sleep 1
    curl --silent --fail --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null && break
  done
fi
curl --silent --fail --max-time 3 http://127.0.0.1:11434/api/tags >/dev/null \
  || { echo "Ollama is not responding on loopback port 11434." >&2; exit 2; }

required_gib=42
[[ "$MODE" == "all" ]] && required_gib=66
available_kib="$(df -Pk "$HOME" | awk 'NR==2 {print $4}')"
available_gib=$((available_kib / 1024 / 1024))
((available_gib >= required_gib)) \
  || { echo "At least ${required_gib} GiB free is required; ${available_gib} GiB is available." >&2; exit 2; }

models=("devstral-small-2:24b" "gpt-oss:20b")
[[ "$MODE" == "all" ]] && models+=("qwen3-coder:30b" "qwen2.5-coder:7b")
for model in "${models[@]}"; do
  ollama pull "$model"
done

support="$HOME/Library/Application Support/GunnAireLocalAI"
mkdir -p "$support/bin"
cat > "$support/bin/codex-local" <<'LAUNCHER'
#!/bin/bash
set -euo pipefail
workspace="${1:-$PWD}"
[[ $# -gt 0 ]] && shift
exec codex --oss --local-provider ollama --model devstral-small-2:24b \
  --sandbox read-only --ask-for-approval on-request --cd "$workspace" "$@"
LAUNCHER
chmod 700 "$support/bin/codex-local"

echo "Installed models:"
ollama list
echo "Guarded launcher: $support/bin/codex-local"
echo "No production service or firewall was changed."
