#!/usr/bin/env bash
set -Eeuo pipefail

# Manage models on a local Ollama server.
#
# What this script does:
#   - lists installed models and their on-disk size
#   - lists currently loaded models and their loaded footprint
#   - pulls exactly one requested model after confirmation
#   - removes exactly one requested model from local storage after confirmation
#   - provides an interactive menu when run with no arguments
#
# What this script does NOT do:
#   - configure OpenShell providers
#   - choose a provider model automatically
#   - manage the remote/global Ollama catalog
#
# Intended usage:
#   ./manage-ollama-models.sh
#   ./manage-ollama-models.sh --list
#   ./manage-ollama-models.sh --status
#   ./manage-ollama-models.sh --load llama3.2:3b
#   ./manage-ollama-models.sh --remove llama3.2:3b
#
# Optional environment variables:
#   OLLAMA_TAGS_URL=http://127.0.0.1:11434/api/tags
#   OLLAMA_PS_URL=http://127.0.0.1:11434/api/ps
#   OLLAMA_PULL_URL=http://127.0.0.1:11434/api/pull
#   OLLAMA_DELETE_URL=http://127.0.0.1:11434/api/delete
#   AUTO_CONFIRM=true
#   QUIET=true

OLLAMA_TAGS_URL="${OLLAMA_TAGS_URL:-http://127.0.0.1:11434/api/tags}"
OLLAMA_PS_URL="${OLLAMA_PS_URL:-http://127.0.0.1:11434/api/ps}"
OLLAMA_PULL_URL="${OLLAMA_PULL_URL:-http://127.0.0.1:11434/api/pull}"
OLLAMA_DELETE_URL="${OLLAMA_DELETE_URL:-http://127.0.0.1:11434/api/delete}"
AUTO_CONFIRM="${AUTO_CONFIRM:-false}"
QUIET="${QUIET:-false}"

TMP_TAGS_JSON="/tmp/ollama-tags.$$.$RANDOM.json"
TMP_PS_JSON="/tmp/ollama-ps.$$.$RANDOM.json"

ACTION=""
MODEL_NAME=""
INTERACTIVE_MODE="false"

log()  { [[ "$QUIET" == "true" ]] || printf '\n==> %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

cleanup() {
  rm -f "$TMP_TAGS_JSON" "$TMP_PS_JSON"
}
trap cleanup EXIT

usage() {
  cat <<'EOF_USAGE'
Usage:
  ./manage-ollama-models.sh
  ./manage-ollama-models.sh --list
  ./manage-ollama-models.sh --status
  ./manage-ollama-models.sh --load <model-name>
  ./manage-ollama-models.sh --remove <model-name>
  ./manage-ollama-models.sh --help

Actions:
  --list               Show installed models and on-disk size
  --status             Show currently loaded models and loaded footprint
  --load <model>       Pull one model if it is not already installed
  --remove <model>     Remove one installed model from local storage
  --help               Show this help

Behavior:
  - No arguments starts an interactive menu.
  - Pull and remove require explicit confirmation unless AUTO_CONFIRM=true.

Notes:
  - "On-disk size" is storage used by the downloaded model files.
  - "Loaded size" is the current base loaded footprint reported by Ollama.
  - Live runtime memory can be higher than loaded size because context,
    KV cache, and concurrency increase memory usage.
EOF_USAGE
}

parse_args() {
  if [[ $# -eq 0 ]]; then
    INTERACTIVE_MODE="true"
    return 0
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --list)
        [[ -z "$ACTION" ]] || die "Specify only one action."
        ACTION="list"
        shift
        ;;
      --status)
        [[ -z "$ACTION" ]] || die "Specify only one action."
        ACTION="status"
        shift
        ;;
      --load)
        [[ -z "$ACTION" ]] || die "Specify only one action."
        [[ $# -ge 2 ]] || die "--load requires a model name."
        ACTION="load"
        MODEL_NAME="$2"
        shift 2
        ;;
      --remove)
        [[ -z "$ACTION" ]] || die "Specify only one action."
        [[ $# -ge 2 ]] || die "--remove requires a model name."
        ACTION="remove"
        MODEL_NAME="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

check_tooling() {
  need_cmd curl
  need_cmd python3
}

fetch_installed_models() {
  log "Checking local Ollama model inventory"
  curl --silent --show-error --fail "$OLLAMA_TAGS_URL" >"$TMP_TAGS_JSON" || \
    die "Cannot reach Ollama at $OLLAMA_TAGS_URL. Make sure Ollama is running and listening on port 11434."
}

fetch_running_models() {
  log "Checking currently loaded Ollama models"
  curl --silent --show-error --fail "$OLLAMA_PS_URL" >"$TMP_PS_JSON" || \
    die "Cannot reach Ollama at $OLLAMA_PS_URL. Make sure Ollama is running and listening on port 11434."
}

print_installed_models() {
  python3 - "$TMP_TAGS_JSON" <<'PY'
import json
import sys

def human_bytes(n):
    n = int(n)
    units = ["B", "KB", "MB", "GB", "TB"]
    value = float(n)
    for unit in units:
        if value < 1024.0 or unit == units[-1]:
            if unit == "B":
                return f"{int(value)} {unit}"
            return f"{value:.1f} {unit}"
        value /= 1024.0

path = sys.argv[1]
with open(path) as f:
    data = json.load(f)

models = data.get("models", [])
rows = []
for m in models:
    if not isinstance(m, dict):
        continue
    name = m.get("name") or "-"
    size = int(m.get("size", 0))
    details = m.get("details") or {}
    params = details.get("parameter_size") or "-"
    quant = details.get("quantization_level") or "-"
    rows.append((name, size, params, quant))

print("\nInstalled models:")
if not rows:
    print("  (no models currently installed)")
    raise SystemExit(0)

name_w = max(len("MODEL"), max(len(r[0]) for r in rows))
size_w = max(len("ON DISK"), max(len(human_bytes(r[1])) for r in rows))
param_w = max(len("PARAMS"), max(len(r[2]) for r in rows))
quant_w = max(len("QUANT"), max(len(r[3]) for r in rows))

header = f"  {'MODEL':<{name_w}}  {'ON DISK':>{size_w}}  {'PARAMS':<{param_w}}  {'QUANT':<{quant_w}}"
print(header)
print("  " + "-" * (len(header) - 2))

for name, size, params, quant in sorted(rows, key=lambda x: x[0].lower()):
    print(f"  {name:<{name_w}}  {human_bytes(size):>{size_w}}  {params:<{param_w}}  {quant:<{quant_w}}")
PY
}

print_running_models() {
  python3 - "$TMP_PS_JSON" <<'PY'
import json
import sys

def human_bytes(n):
    n = int(n)
    units = ["B", "KB", "MB", "GB", "TB"]
    value = float(n)
    for unit in units:
        if value < 1024.0 or unit == units[-1]:
            if unit == "B":
                return f"{int(value)} {unit}"
            return f"{value:.1f} {unit}"
        value /= 1024.0

path = sys.argv[1]
with open(path) as f:
    data = json.load(f)

models = data.get("models", [])
rows = []
for m in models:
    if not isinstance(m, dict):
        continue
    name = m.get("name") or "-"
    loaded = int(m.get("size", 0))
    vram = int(m.get("size_vram", 0))
    ctx = m.get("context_length")
    rows.append((name, loaded, vram, str(ctx) if ctx is not None else "-"))

print("\nCurrently loaded models:")
if not rows:
    print("  (no models currently loaded)")
    raise SystemExit(0)

name_w = max(len("MODEL"), max(len(r[0]) for r in rows))
load_w = max(len("LOADED"), max(len(human_bytes(r[1])) for r in rows))
vram_w = max(len("VRAM"), max(len(human_bytes(r[2])) for r in rows))
ctx_w = max(len("CTX"), max(len(r[3]) for r in rows))

header = f"  {'MODEL':<{name_w}}  {'LOADED':>{load_w}}  {'VRAM':>{vram_w}}  {'CTX':>{ctx_w}}"
print(header)
print("  " + "-" * (len(header) - 2))

for name, loaded, vram, ctx in sorted(rows, key=lambda x: x[0].lower()):
    print(f"  {name:<{name_w}}  {human_bytes(loaded):>{load_w}}  {human_bytes(vram):>{vram_w}}  {ctx:>{ctx_w}}")

print("\nNotes:")
print("  LOADED is the current base loaded footprint reported by Ollama.")
print("  VRAM is the portion currently resident in GPU memory.")
print("  Actual live memory use can grow with context, KV cache, and concurrency.")
PY
}

model_exists_locally() {
  python3 - "$MODEL_NAME" "$TMP_TAGS_JSON" <<'PY'
import json
import sys

model = sys.argv[1]
path = sys.argv[2]

with open(path) as f:
    data = json.load(f)

models = {
    m.get("name")
    for m in data.get("models", [])
    if isinstance(m, dict) and m.get("name")
}

print("true" if model in models else "false")
PY
}

confirm_action() {
  local verb="$1"
  local message="$2"

  if [[ "$AUTO_CONFIRM" == "true" ]]; then
    log "AUTO_CONFIRM=true, proceeding without prompt"
    return 0
  fi

  printf '\n%s\n' "$message"
  printf '\nDo you want to %s this model now? [y/N]\n' "$verb"

  read -r reply
  case "${reply:-}" in
    y|Y|yes|YES)
      return 0
      ;;
    *)
      die "Operation cancelled. No changes were made."
      ;;
  esac
}

prompt_for_model_name() {
  local prompt_text="$1"
  printf '\n%s\n' "$prompt_text"
  read -r MODEL_NAME
  [[ -n "${MODEL_NAME:-}" ]] || die "No model name entered."
}

pull_model() {
  log "Pulling model: $MODEL_NAME"
  curl --silent --show-error --fail \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MODEL_NAME\",\"stream\":true}" \
    "$OLLAMA_PULL_URL" | python3 - <<'PY'
import json
import sys

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        print(line)
        continue

    status = obj.get("status")
    total = obj.get("total")
    completed = obj.get("completed")

    if status and total is not None and completed is not None and total:
        pct = (completed / total) * 100.0
        print(f"{status} ({pct:.1f}%)")
    elif status:
        print(status)
    else:
        print(obj)
PY
}

remove_model() {
  log "Removing model from local storage: $MODEL_NAME"
  curl --silent --show-error --fail \
    -X DELETE \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MODEL_NAME\"}" \
    "$OLLAMA_DELETE_URL" >/dev/null
}

verify_model_present_after_pull() {
  fetch_installed_models
  local exists
  exists="$(model_exists_locally)"
  [[ "$exists" == "true" ]] || die "Pull completed but the model is still not present: $MODEL_NAME"
}

verify_model_absent_after_remove() {
  fetch_installed_models
  local exists
  exists="$(model_exists_locally)"
  [[ "$exists" == "false" ]] || die "Remove completed but the model still appears present: $MODEL_NAME"
}

do_list() {
  fetch_installed_models
  print_installed_models
}

do_status() {
  fetch_running_models
  print_running_models
}

do_summary() {
  fetch_installed_models
  print_installed_models
  fetch_running_models
  print_running_models
}

do_load() {
  fetch_installed_models
  local exists
  exists="$(model_exists_locally)"

  if [[ "$exists" == "true" ]]; then
    log "Requested model is already installed: $MODEL_NAME"
    print_installed_models
    return 0
  fi

  confirm_action \
    "pull" \
    "The requested model is not currently installed on this Ollama server:

  $MODEL_NAME

Pulling a model may take time and consume network bandwidth and disk space."

  pull_model
  verify_model_present_after_pull

  log "Model is now installed: $MODEL_NAME"
  print_installed_models
}

do_remove() {
  fetch_installed_models
  local exists
  exists="$(model_exists_locally)"

  if [[ "$exists" != "true" ]]; then
    die "Cannot remove model because it is not installed locally: $MODEL_NAME"
  fi

  confirm_action \
    "remove from local storage" \
    "The following installed model will be removed from local Ollama storage:

  $MODEL_NAME

This deletes the local model files from disk.
It does not change your OpenShell provider configuration."

  remove_model
  verify_model_absent_after_remove

  log "Model has been removed from local storage: $MODEL_NAME"
  print_installed_models
}

interactive_menu() {
  while true; do
    printf '\n'
    printf '%s\n' 'Ollama Model Manager'
    printf '%s\n' '--------------------'
    printf '%s\n' '1) Show installed models'
    printf '%s\n' '2) Pull a model'
    printf '%s\n' '3) Remove a model from local storage'
    printf '%s\n' 'q) Quit'
    printf '\nSelect an option: '

    read -r choice

    case "${choice:-}" in
      1)
        do_summary
        ;;
      2)
        do_list
        prompt_for_model_name "Enter the model name to pull:"
        do_load
        ;;
      3)
        do_list
        prompt_for_model_name "Enter the model name to remove from local storage:"
        do_remove
        ;;
      q|Q)
        printf '\nExiting.\n'
        break
        ;;
      *)
        warn "Unknown selection: ${choice:-}"
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  check_tooling

  if [[ "$INTERACTIVE_MODE" == "true" ]]; then
    interactive_menu
    exit 0
  fi

  case "$ACTION" in
    list)
      do_list
      ;;
    status)
      do_status
      ;;
    load)
      do_load
      ;;
    remove)
      do_remove
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"