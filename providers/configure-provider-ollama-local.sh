#!/usr/bin/env bash
set -Eeuo pipefail

# Create or refresh an OpenShell provider for a local Ollama instance.
#
# Human-facing behavior:
#   - With no arguments, report current local Ollama provider status only.
#   - With arguments, optionally create/refresh the provider and activate a
#     locally installed Ollama model for gateway inference.
#
# Notes:
#   - This script does NOT pull models into Ollama.
#   - A requested model must already exist on the local Ollama server.
#   - Use ./providers/manage-ollama-models.sh to inspect, pull, or remove
#     local Ollama models.

PROVIDER_NAME="${PROVIDER_NAME:-ollama-local}"
PROVIDER_TYPE="${PROVIDER_TYPE:-openai}"
OPENAI_BASE_URL="${OPENAI_BASE_URL:-http://host.openshell.internal:11434/v1}"
OPENAI_API_KEY_VALUE="${OPENAI_API_KEY_VALUE:-empty}"
OLLAMA_HOST_CHECK_URL="${OLLAMA_HOST_CHECK_URL:-http://127.0.0.1:11434/api/tags}"
FORCE_RECREATE_PROVIDER="${FORCE_RECREATE_PROVIDER:-true}"
ACTIVATE="${ACTIVATE:-false}"
MODEL_NAME="${MODEL_NAME:-}"
INFERENCE_NO_VERIFY="${INFERENCE_NO_VERIFY:-false}"
SKIP_OLLAMA_HOST_CHECK="${SKIP_OLLAMA_HOST_CHECK:-false}"
SKIP_MODEL_PRESENCE_CHECK="${SKIP_MODEL_PRESENCE_CHECK:-false}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_MANAGER_SCRIPT="${MODEL_MANAGER_SCRIPT:-$SCRIPT_DIR/manage-ollama-models.sh}"

TMP_OLLAMA_TAGS_JSON="/tmp/ollama-tags.json"
STATUS_ONLY="false"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

usage() {
  cat <<EOF_USAGE
Usage:
  ./configure-provider-ollama-local.sh
  ./configure-provider-ollama-local.sh --status
  ./configure-provider-ollama-local.sh --model qwen3.5:9b --activate
  ./configure-provider-ollama-local.sh --provider-name ollama-local --base-url http://host.openshell.internal:11434/v1
  ./configure-provider-ollama-local.sh --model qwen3.5:9b --activate --force-recreate
  ./configure-provider-ollama-local.sh --model qwen3.5:9b --activate --no-verify

Behavior:
  - With no arguments, report current local Ollama provider status only.
  - This script does not pull models into Ollama.
  - A model must already exist locally before it can be activated.
  - --model by itself does not activate anything; use --activate as well.

Options:
  --status                 Show current provider and gateway inference status
  --provider-name NAME     Provider name to create or refresh
  --base-url URL           Ollama OpenAI-compatible base URL
  --model NAME             Local Ollama model name to use
  --activate               Switch gateway inference to the named model
  --force-recreate         Recreate the provider definition if it exists
  --no-force-recreate      Do not recreate the provider definition
  --no-verify              Pass --no-verify when activating inference
  --skip-ollama-check      Skip checking the Ollama host endpoint
  --skip-model-check       Skip checking whether the model exists locally
  --help                   Show this help

Environment variable equivalents:
  PROVIDER_NAME
  OPENAI_BASE_URL
  MODEL_NAME
  ACTIVATE
  FORCE_RECREATE_PROVIDER
  INFERENCE_NO_VERIFY
  SKIP_OLLAMA_HOST_CHECK
  SKIP_MODEL_PRESENCE_CHECK
EOF_USAGE
}

parse_args() {
  if [[ $# -eq 0 ]]; then
    STATUS_ONLY="true"
    return 0
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status)
        STATUS_ONLY="true"
        shift
        ;;
      --provider-name)
        [[ $# -ge 2 ]] || die "--provider-name requires a value."
        PROVIDER_NAME="$2"
        shift 2
        ;;
      --base-url)
        [[ $# -ge 2 ]] || die "--base-url requires a value."
        OPENAI_BASE_URL="$2"
        shift 2
        ;;
      --model)
        [[ $# -ge 2 ]] || die "--model requires a value."
        MODEL_NAME="$2"
        shift 2
        ;;
      --activate)
        ACTIVATE="true"
        shift
        ;;
      --force-recreate)
        FORCE_RECREATE_PROVIDER="true"
        shift
        ;;
      --no-force-recreate)
        FORCE_RECREATE_PROVIDER="false"
        shift
        ;;
      --no-verify)
        INFERENCE_NO_VERIFY="true"
        shift
        ;;
      --skip-ollama-check)
        SKIP_OLLAMA_HOST_CHECK="true"
        shift
        ;;
      --skip-model-check)
        SKIP_MODEL_PRESENCE_CHECK="true"
        shift
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

  if [[ "$STATUS_ONLY" == "true" && "$ACTIVATE" == "true" ]]; then
    die "--status cannot be combined with --activate."
  fi
}

check_tooling() {
  need_cmd openshell
  need_cmd curl
  need_cmd python3
}

check_gateway() {
  log "Checking OpenShell gateway state"
  openshell status >/dev/null 2>&1 || \
    die "OpenShell gateway is not reachable. Run NemoClaw onboarding first and confirm the gateway is up."
}

check_ollama_host() {
  if [[ "$SKIP_OLLAMA_HOST_CHECK" == "true" ]]; then
    warn "Skipping Ollama host endpoint check (SKIP_OLLAMA_HOST_CHECK=true)."
    return 0
  fi

  log "Checking host Ollama endpoint"
  curl --silent --show-error --fail "$OLLAMA_HOST_CHECK_URL" >"$TMP_OLLAMA_TAGS_JSON" || \
    die "Cannot reach Ollama at $OLLAMA_HOST_CHECK_URL. Make sure Ollama is running on the host and listening on port 11434."
}

maybe_check_model_presence() {
  if [[ -z "$MODEL_NAME" ]]; then
    return 0
  fi

  if [[ "$SKIP_MODEL_PRESENCE_CHECK" == "true" ]]; then
    warn "Skipping model presence check (SKIP_MODEL_PRESENCE_CHECK=true)."
    return 0
  fi

  if [[ ! -f "$TMP_OLLAMA_TAGS_JSON" ]]; then
    check_ollama_host
  fi

  log "Checking that the requested model exists in local Ollama inventory"
  if ! python3 - "$MODEL_NAME" "$TMP_OLLAMA_TAGS_JSON" <<'PY'
import json
import sys

model = sys.argv[1]
path = sys.argv[2]

with open(path) as f:
    data = json.load(f)

models = {m.get('name') for m in data.get('models', []) if isinstance(m, dict)}
if model not in models:
    raise SystemExit(1)
print(f"Found model in Ollama catalog: {model}")
PY
  then
    cat >&2 <<EOF_MISSING

[ERROR] Requested model is not present in the local Ollama catalog:

  $MODEL_NAME

This script only activates models that already exist on the local Ollama server.
It does not pull models automatically.

Use the local model manager first:
  $MODEL_MANAGER_SCRIPT

For example:
  $MODEL_MANAGER_SCRIPT
  $MODEL_MANAGER_SCRIPT --load '$MODEL_NAME'

After the model has been pulled into Ollama, run this script again.

EOF_MISSING
    exit 1
  fi
}

provider_exists() {
  openshell provider get "$PROVIDER_NAME" >/dev/null 2>&1
}

remove_provider_if_requested() {
  if [[ "$FORCE_RECREATE_PROVIDER" != "true" ]]; then
    return 0
  fi

  if provider_exists; then
    log "Removing existing provider: $PROVIDER_NAME"
    openshell provider delete "$PROVIDER_NAME"
  fi
}

create_provider() {
  log "Creating provider: $PROVIDER_NAME"
  openshell provider create \
    --name "$PROVIDER_NAME" \
    --type "$PROVIDER_TYPE" \
    --credential "OPENAI_API_KEY=$OPENAI_API_KEY_VALUE" \
    --config "OPENAI_BASE_URL=$OPENAI_BASE_URL"
}

ensure_provider_present() {
  if provider_exists && [[ "$FORCE_RECREATE_PROVIDER" != "true" ]]; then
    log "Provider already exists: $PROVIDER_NAME"
    return 0
  fi

  remove_provider_if_requested
  create_provider
}

maybe_activate_provider() {
  if [[ "$ACTIVATE" != "true" ]]; then
    return 0
  fi

  [[ -n "$MODEL_NAME" ]] || die "--activate requires --model <model-name>."

  log "Switching gateway inference to provider '$PROVIDER_NAME' with model '$MODEL_NAME'"
  if [[ "$INFERENCE_NO_VERIFY" == "true" ]]; then
    openshell inference set --provider "$PROVIDER_NAME" --model "$MODEL_NAME" --no-verify
  else
    openshell inference set --provider "$PROVIDER_NAME" --model "$MODEL_NAME"
  fi
}

print_gateway_inference_status() {
  local inference_output
  inference_output="$(openshell inference get 2>/dev/null || true)"

  printf '\nCurrent gateway inference:\n'

  if [[ -z "$inference_output" ]]; then
    printf '  Unable to read gateway inference status\n'
    return 0
  fi

  python3 - "$inference_output" <<'PY'
import re
import sys

text = sys.argv[1]

# Strip ANSI escape codes just in case.
text = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', text)

lines = text.splitlines()
capturing = False
captured = []

for line in lines:
    stripped = line.strip()

    if 'Gateway inference:' in stripped:
        capturing = True
        continue

    if 'System inference:' in stripped and capturing:
        break

    if capturing:
        if not stripped:
            continue
        captured.append(line)

if captured:
    for line in captured:
        print(line)
else:
    print('  Not configured')
PY
}

show_status_summary() {
  cat <<EOF_STATUS

Local Ollama provider status

Provider name:
  $PROVIDER_NAME

Provider base URL:
  $OPENAI_BASE_URL
EOF_STATUS

  if provider_exists; then
    printf '\nProvider definition:\n'
    printf '  Present\n'
  else
    printf '\nProvider definition:\n'
    printf '  Not present\n'
  fi

  print_gateway_inference_status

  cat <<EOF_NEXT

Helpful follow-up:
  Manage local Ollama models: $MODEL_MANAGER_SCRIPT
  Show provider details:      openshell provider get $PROVIDER_NAME
  Show all providers:         openshell provider list
EOF_NEXT
}

show_change_summary() {
  cat <<EOF_SUMMARY

Ollama provider configuration complete.

Provider name:
  $PROVIDER_NAME

Provider base URL:
  $OPENAI_BASE_URL
EOF_SUMMARY

  if [[ "$ACTIVATE" == "true" ]]; then
    printf '\nRequested change:\n'
    printf '  Gateway inference switched to model: %s\n' "$MODEL_NAME"
  else
    printf '\nRequested change:\n'
    printf '  Provider created or refreshed only\n'
    printf '  Active gateway inference selection was not changed by this run\n'
  fi

  print_gateway_inference_status

  cat <<EOF_NEXT

Helpful follow-up:
  Manage local Ollama models: $MODEL_MANAGER_SCRIPT
  Show provider details:      openshell provider get $PROVIDER_NAME
  Show all providers:         openshell provider list
EOF_NEXT
}

main() {
  parse_args "$@"
  check_tooling
  check_gateway
  check_ollama_host

  if [[ "$STATUS_ONLY" == "true" ]]; then
    log "Status mode: reporting current local Ollama provider status only"
    show_status_summary
    exit 0
  fi

  maybe_check_model_presence
  ensure_provider_present
  maybe_activate_provider
  show_change_summary
}

main "$@"