#!/usr/bin/env bash
set -Eeuo pipefail

# Configure the OpenShell gateway to use a selected upstream LLM provider.
#
# This version separates four concerns:
#   1) gateway provider definition
#   2) host-side endpoint probing
#   3) optional model catalog checking
#   4) inference activation
#
# Intended usage:
#   - Run AFTER `nemoclaw onboard`
#   - Create or refresh one named gateway-side provider record
#   - Optionally activate that provider/model for gateway inference
#
# This script configures the gateway provider only.
# It does NOT install model servers and does NOT manage local model inventory.

PROVIDER_NAME="${PROVIDER_NAME:-}"
PROVIDER_TYPE="${PROVIDER_TYPE:-openai}"
OPENAI_BASE_URL="${OPENAI_BASE_URL:-http://host.openshell.internal:11434/v1}"
OPENAI_API_KEY_VALUE="${OPENAI_API_KEY_VALUE:-empty}"
BACKEND_HINT="${BACKEND_HINT:-ollama}"   # ollama | vllm | generic
FORCE_RECREATE_PROVIDER="${FORCE_RECREATE_PROVIDER:-true}"
ACTIVATE="${ACTIVATE:-false}"
MODEL_NAME="${MODEL_NAME:-}"
INFERENCE_NO_VERIFY="${INFERENCE_NO_VERIFY:-false}"
SKIP_ENDPOINT_CHECK="${SKIP_ENDPOINT_CHECK:-false}"
SKIP_MODEL_CHECK="${SKIP_MODEL_CHECK:-false}"
STATUS_ONLY="false"

PROBE_BASE_URL="${PROBE_BASE_URL:-}"
LIST_PROVIDERS="false"
USE_ONBOARDING="false"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_MANAGER_SCRIPT="${MODEL_MANAGER_SCRIPT:-$SCRIPT_DIR/manage-ollama-models.sh}"
ONBOARD_SESSION_PATH="${ONBOARD_SESSION_PATH:-$HOME/.nemoclaw/onboard-session.json}"
TMP_ENDPOINT_JSON="/tmp/gateway-provider-check.$$.$RANDOM.json"
SCRIPT_PATH="${SCRIPT_PATH:-$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")}"
DISPLAY_SCRIPT_PATH="${DISPLAY_SCRIPT_PATH:-./providers/$(basename "${BASH_SOURCE[0]}")}"
DISPLAY_MODEL_MANAGER_PATH="${DISPLAY_MODEL_MANAGER_PATH:-./providers/$(basename "$MODEL_MANAGER_SCRIPT")}"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

validation_backend() {
  case "$PROVIDER_TYPE" in
    nvidia)
      printf '%s' "nvidia"
      ;;
    openai)
      case "$BACKEND_HINT" in
        ollama|vllm)
          printf '%s' "$BACKEND_HINT"
          ;;
        generic|*)
          printf '%s' "openai-compatible"
          ;;
      esac
      ;;
    *)
      printf '%s' "generic"
      ;;
  esac
}

provider_label() {
  case "$(validation_backend)" in
    nvidia)
      printf '%s' "NVIDIA Endpoints"
      ;;
    ollama)
      printf '%s' "Ollama"
      ;;
    vllm)
      printf '%s' "vLLM"
      ;;
    openai-compatible)
      printf '%s' "OpenAI-compatible provider"
      ;;
    generic)
      printf '%s' "provider"
      ;;
  esac
}

provider_credential_key() {
  case "$PROVIDER_TYPE" in
    nvidia)
      printf '%s' "NVIDIA_API_KEY"
      ;;
    *)
      printf '%s' "OPENAI_API_KEY"
      ;;
  esac
}

provider_base_url_key() {
  case "$PROVIDER_TYPE" in
    nvidia)
      printf '%s' "NVIDIA_BASE_URL"
      ;;
    *)
      printf '%s' "OPENAI_BASE_URL"
      ;;
  esac
}

cleanup() {
  rm -f "$TMP_ENDPOINT_JSON"
}
trap cleanup EXIT

usage() {
  cat <<'EOF_USAGE'
Usage:
  ./configure-gateway-provider.sh
  ./configure-gateway-provider.sh --status
  ./configure-gateway-provider.sh --model <model-name> --activate [options]

Behavior:
  - With no arguments, report current gateway provider status only.
  - This script configures the OpenShell gateway provider.
  - It does not install model servers.
  - It does not pull or remove local Ollama models.
  - --model by itself does not activate anything; use --activate as well.

Options:
  --status                    Show current gateway provider and inference status
  --list-providers            Show all configured gateway providers
  --use-onboarding            Switch back to the original onboarding provider/model
  --provider-name NAME        Provider name to create or refresh
  --provider-type TYPE        Provider type (default: openai)
  --base-url URL              Gateway-visible upstream OpenAI-compatible base URL
  --probe-base-url URL        Host-side base URL used only for validation
  --api-key VALUE             Upstream API key or placeholder value
  --backend HINT              ollama, vllm, or generic (default: ollama)
  --model NAME                Model name or model ID to use
  --activate                  Switch gateway inference to this provider/model
  --force-recreate            Recreate the provider definition if it exists
  --no-force-recreate         Keep the existing provider definition if present
  --no-verify                 Pass --no-verify when activating inference
  --skip-endpoint-check       Skip checking the upstream endpoint
  --skip-model-check          Skip checking whether the model appears upstream
  --help                      Show this help

Environment variable equivalents:
  PROVIDER_NAME
  PROVIDER_TYPE
  OPENAI_BASE_URL
  PROBE_BASE_URL
  OPENAI_API_KEY_VALUE
  BACKEND_HINT
  MODEL_NAME
  ACTIVATE
  FORCE_RECREATE_PROVIDER
  INFERENCE_NO_VERIFY
  SKIP_ENDPOINT_CHECK
  SKIP_MODEL_CHECK
EOF_USAGE
}

resolve_defaults() {
  case "$(validation_backend)" in
    nvidia)
      [[ -n "$PROVIDER_NAME" ]] || PROVIDER_NAME="nvidia-prod"
      ;;
    ollama)
      [[ -n "$PROVIDER_NAME" ]] || PROVIDER_NAME="ollama-local"
      [[ -n "$PROBE_BASE_URL" ]] || PROBE_BASE_URL="http://127.0.0.1:11434"
      if [[ "$OPENAI_BASE_URL" == "http://host.openshell.internal:11434/v1" ]]; then
        OPENAI_BASE_URL="http://host.openshell.internal:11434/v1"
      fi
      ;;
    vllm)
      [[ -n "$PROVIDER_NAME" ]] || PROVIDER_NAME="vllm-local"
      [[ -n "$PROBE_BASE_URL" ]] || PROBE_BASE_URL="http://127.0.0.1:8000/v1"
      if [[ "$OPENAI_BASE_URL" == "http://host.openshell.internal:11434/v1" ]]; then
        OPENAI_BASE_URL="http://host.openshell.internal:8000/v1"
      fi
      ;;
    openai-compatible|generic)
      [[ -n "$PROVIDER_NAME" ]] || PROVIDER_NAME="gateway-provider"
      ;;
    *)
      die "Unsupported provider validation path for provider type '$PROVIDER_TYPE' and backend hint '$BACKEND_HINT'."
      ;;
  esac
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
      --list-providers)
        LIST_PROVIDERS="true"
        shift
        ;;
      --use-onboarding)
        USE_ONBOARDING="true"
        shift
        ;;
      --provider-name)
        [[ $# -ge 2 ]] || die "--provider-name requires a value."
        PROVIDER_NAME="$2"
        shift 2
        ;;
      --provider-type)
        [[ $# -ge 2 ]] || die "--provider-type requires a value."
        PROVIDER_TYPE="$2"
        shift 2
        ;;
      --base-url)
        [[ $# -ge 2 ]] || die "--base-url requires a value."
        OPENAI_BASE_URL="$2"
        shift 2
        ;;
      --probe-base-url)
        [[ $# -ge 2 ]] || die "--probe-base-url requires a value."
        PROBE_BASE_URL="$2"
        shift 2
        ;;
      --api-key)
        [[ $# -ge 2 ]] || die "--api-key requires a value."
        OPENAI_API_KEY_VALUE="$2"
        shift 2
        ;;
      --backend)
        [[ $# -ge 2 ]] || die "--backend requires a value."
        BACKEND_HINT="$2"
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
      --skip-endpoint-check)
        SKIP_ENDPOINT_CHECK="true"
        shift
        ;;
      --skip-model-check)
        SKIP_MODEL_CHECK="true"
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

  if [[ "$LIST_PROVIDERS" == "true" && "$ACTIVATE" == "true" ]]; then
    die "--list-providers cannot be combined with --activate."
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

endpoint_probe_url() {
  local base
  if [[ -n "$PROBE_BASE_URL" ]]; then
    base="$PROBE_BASE_URL"
  else
    base="$OPENAI_BASE_URL"
  fi

  case "$(validation_backend)" in
    ollama)
      printf '%s' "${base%/v1}/api/tags"
      ;;
    nvidia|vllm|openai-compatible|generic)
      printf '%s' "${base%/}/models"
      ;;
  esac
}

curl_auth_args() {
  if [[ -n "$OPENAI_API_KEY_VALUE" && "$OPENAI_API_KEY_VALUE" != "empty" ]]; then
    printf '%s\n' "-H" "Authorization: Bearer $OPENAI_API_KEY_VALUE"
  fi
}

check_openai_compatible_endpoint() {
  local base responses_url chat_url
  local -a auth_args=()

  if [[ -n "$PROBE_BASE_URL" ]]; then
    base="$PROBE_BASE_URL"
  else
    base="$OPENAI_BASE_URL"
  fi

  mapfile -t auth_args < <(curl_auth_args)
  responses_url="${base%/}/responses"
  chat_url="${base%/}/chat/completions"

  if [[ -z "$MODEL_NAME" ]]; then
    warn "No model was supplied for OpenAI-compatible endpoint validation; falling back to a catalog check."
    local probe_url
    probe_url="$(endpoint_probe_url)"
    log "Checking $(provider_label) endpoint"
    curl --silent --show-error --fail "${auth_args[@]}" "$probe_url" >"$TMP_ENDPOINT_JSON" || \
      die "Cannot reach $(provider_label) endpoint at $probe_url with the current provider settings. Check network reachability from the Jetson host, the base URL, and the API key."
    return 0
  fi

  log "Checking $(provider_label) endpoint with a real inference request"
  if curl --silent --show-error --fail \
    "${auth_args[@]}" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL_NAME\",\"input\":\"ping\",\"max_output_tokens\":1}" \
    "$responses_url" >"$TMP_ENDPOINT_JSON"; then
    return 0
  fi

  curl --silent --show-error --fail \
    "${auth_args[@]}" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":1}" \
    "$chat_url" >"$TMP_ENDPOINT_JSON" || \
    die "Cannot complete an OpenAI-compatible validation request against $base. Tried /responses and /chat/completions with model '$MODEL_NAME'. Check the base URL, API key, and model name."
}

check_endpoint() {
  if [[ "$SKIP_ENDPOINT_CHECK" == "true" ]]; then
    warn "Skipping upstream endpoint check (SKIP_ENDPOINT_CHECK=true)."
    return 0
  fi

  case "$(validation_backend)" in
    openai-compatible)
      check_openai_compatible_endpoint
      ;;
    *)
      local probe_url
      local -a curl_args=(
        --silent
        --show-error
        --fail
      )
      probe_url="$(endpoint_probe_url)"

      if [[ -n "$OPENAI_API_KEY_VALUE" && "$OPENAI_API_KEY_VALUE" != "empty" ]]; then
        curl_args+=(-H "Authorization: Bearer $OPENAI_API_KEY_VALUE")
      fi

      log "Checking $(provider_label) endpoint"
      curl "${curl_args[@]}" "$probe_url" >"$TMP_ENDPOINT_JSON" || \
        die "Cannot reach $(provider_label) endpoint at $probe_url with the current provider settings. Check network reachability from the Jetson host, the base URL, and the API key."
      ;;
  esac
}

maybe_check_model_presence() {
  if [[ -z "$MODEL_NAME" ]]; then
    return 0
  fi

  if [[ "$SKIP_MODEL_CHECK" == "true" ]]; then
    warn "Skipping model presence check (SKIP_MODEL_CHECK=true)."
    return 0
  fi

  if [[ ! -f "$TMP_ENDPOINT_JSON" ]]; then
    if [[ "$SKIP_ENDPOINT_CHECK" == "true" ]]; then
      warn "Skipping model presence check because endpoint probing was skipped and no endpoint catalog is available."
      return 0
    fi
    check_endpoint
  fi

  case "$(validation_backend)" in
    nvidia)
      log "Skipping preflight model catalog check for NVIDIA Endpoints"
      warn "NVIDIA Endpoints model validation is deferred to OpenShell activation for provider '$PROVIDER_NAME'."
      ;;
    ollama)
      log "Checking that the requested model exists in the upstream catalog"
      if ! python3 - "$MODEL_NAME" "$TMP_ENDPOINT_JSON" <<'PY'
import json
import sys
model = sys.argv[1]
path = sys.argv[2]
with open(path) as f:
    data = json.load(f)
models = {m.get('name') for m in data.get('models', []) if isinstance(m, dict)}
if model not in models:
    raise SystemExit(1)
print(f"Found model in upstream catalog: {model}")
PY
      then
        cat >&2 <<EOF_MISSING

[ERROR] Requested model is not present in the upstream Ollama catalog:

  $MODEL_NAME

This script configures the gateway provider only.
It does not pull models into Ollama.

Use the local model manager first if this is the Jetson host Ollama server:
  $MODEL_MANAGER_SCRIPT

For example:
  $MODEL_MANAGER_SCRIPT
  $MODEL_MANAGER_SCRIPT --load '$MODEL_NAME'

Then run this script again.

EOF_MISSING
        exit 1
      fi
      ;;
    vllm)
      log "Checking that the requested model exists in the upstream catalog"
      python3 - "$MODEL_NAME" "$TMP_ENDPOINT_JSON" <<'PY'
import json
import sys
model = sys.argv[1]
path = sys.argv[2]
with open(path) as f:
    data = json.load(f)
models = set()
for m in data.get('data', []):
    if isinstance(m, dict) and m.get('id'):
        models.add(m['id'])
if model not in models:
    raise SystemExit(f"Model not present in upstream catalog: {model}")
print(f"Found model in upstream catalog: {model}")
PY
      ;;
    openai-compatible)
      log "OpenAI-compatible endpoint validation already exercised the requested model"
      ;;
    generic)
      log "Skipping preflight model catalog check for $(provider_label)"
      warn "Model validation is deferred to OpenShell activation for provider '$PROVIDER_NAME'."
      ;;
  esac
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
  local credential_key config_key
  credential_key="$(provider_credential_key)"
  config_key="$(provider_base_url_key)"

  log "Creating provider: $PROVIDER_NAME"
  openshell provider create \
    --name "$PROVIDER_NAME" \
    --type "$PROVIDER_TYPE" \
    --credential "$credential_key=$OPENAI_API_KEY_VALUE" \
    --config "$config_key=$OPENAI_BASE_URL"
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

get_active_provider_and_model() {
  local inference_output
  inference_output="$(openshell inference get 2>/dev/null || true)"

  python3 - "$inference_output" <<'PY'
import re
import sys

text = sys.argv[1]
text = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', text)
provider = ''
model = ''
capturing = False

for line in text.splitlines():
    stripped = line.strip()
    if 'Gateway inference:' in stripped:
        capturing = True
        continue
    if 'System inference:' in stripped and capturing:
        break
    if not capturing:
        continue
    if stripped.startswith('Provider:'):
        provider = stripped.split(':', 1)[1].strip()
    elif stripped.startswith('Model:'):
        model = stripped.split(':', 1)[1].strip()

print(provider)
print(model)
PY
}

get_onboarding_provider_and_model() {
  if [[ ! -f "$ONBOARD_SESSION_PATH" ]]; then
    return 0
  fi

  python3 - "$ONBOARD_SESSION_PATH" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path) as f:
    data = json.load(f)

provider = data.get('provider') or ''
model = data.get('model') or ''
print(provider)
print(model)
PY
}

print_onboarding_summary_if_available() {
  local -a onboarding_data=()
  local onboarding_provider onboarding_model

  mapfile -t onboarding_data < <(get_onboarding_provider_and_model)
  onboarding_provider="${onboarding_data[0]:-}"
  onboarding_model="${onboarding_data[1]:-}"

  if [[ -z "$onboarding_provider" && -z "$onboarding_model" ]]; then
    return 0
  fi

  printf '\nOriginal onboarding selection:\n'
  [[ -n "$onboarding_provider" ]] && printf '  Provider: %s\n' "$onboarding_provider"
  [[ -n "$onboarding_model" ]] && printf '  Model:    %s\n' "$onboarding_model"
}

print_switch_back_hint_if_available() {
  local active_provider active_model onboarding_provider onboarding_model
  local -a active_pm=() onboarding_data=()

  mapfile -t active_pm < <(get_active_provider_and_model)
  active_provider="${active_pm[0]:-}"
  active_model="${active_pm[1]:-}"

  mapfile -t onboarding_data < <(get_onboarding_provider_and_model)
  onboarding_provider="${onboarding_data[0]:-}"
  onboarding_model="${onboarding_data[1]:-}"

  if [[ -z "$onboarding_provider" || -z "$onboarding_model" ]]; then
    return 0
  fi

  if [[ "$active_provider" == "$onboarding_provider" && "$active_model" == "$onboarding_model" ]]; then
    return 0
  fi

  printf '  Switch back to onboarding: %s --use-onboarding\n' "$DISPLAY_SCRIPT_PATH"
}

load_onboarding_selection() {
  local -a onboarding_data=()

  mapfile -t onboarding_data < <(get_onboarding_provider_and_model)
  PROVIDER_NAME="${onboarding_data[0]:-}"
  MODEL_NAME="${onboarding_data[1]:-}"

  [[ -n "$PROVIDER_NAME" ]] || die "No onboarding provider found in $ONBOARD_SESSION_PATH."
  [[ -n "$MODEL_NAME" ]] || die "No onboarding model found in $ONBOARD_SESSION_PATH."

  ACTIVATE="true"
  FORCE_RECREATE_PROVIDER="false"
  SKIP_ENDPOINT_CHECK="true"
  SKIP_MODEL_CHECK="true"
}

validate_use_onboarding_preconditions() {
  if [[ "$USE_ONBOARDING" != "true" ]]; then
    return 0
  fi

  if provider_exists; then
    return 0
  fi

  die "The onboarding provider '$PROVIDER_NAME' is not currently defined in OpenShell. This restore mode can only re-select an existing provider definition. Re-run onboarding or recreate the provider with explicit settings first."
}

show_all_providers() {
  printf '\nConfigured gateway providers:\n\n'
  openshell provider list
}

show_status_summary() {
  cat <<EOF_STATUS

Gateway provider status

Configured target provider:
  $PROVIDER_NAME
EOF_STATUS

  if provider_exists; then
    printf '\nConfigured target provider definition:\n'
    printf '  Present\n'
  else
    printf '\nConfigured target provider definition:\n'
    printf '  Not present\n'
  fi

  if [[ -n "$OPENAI_BASE_URL" ]]; then
    printf '\nGateway base URL for this target:\n'
    printf '  %s\n' "$OPENAI_BASE_URL"
  fi

  if [[ -n "$PROBE_BASE_URL" ]]; then
    printf '\nHost-side probe base URL for this target:\n'
    printf '  %s\n' "$PROBE_BASE_URL"
  fi

  print_gateway_inference_status
  print_onboarding_summary_if_available

  cat <<EOF_NEXT

Helpful follow-up:
  Script usage:              $DISPLAY_SCRIPT_PATH --help
  Show all providers:        $DISPLAY_SCRIPT_PATH --list-providers
EOF_NEXT
  print_switch_back_hint_if_available
  if [[ "$(validation_backend)" == "ollama" ]]; then
    printf '  Local model manager:     %s\n' "$DISPLAY_MODEL_MANAGER_PATH"
  fi
}

show_change_summary() {
  cat <<EOF_SUMMARY

Gateway provider configuration complete.

Provider name:
  $PROVIDER_NAME
EOF_SUMMARY

  printf '\nConfigured provider base URL:\n'
  printf '  %s\n' "$OPENAI_BASE_URL"
  if [[ -n "$PROBE_BASE_URL" ]]; then
    printf '\nValidation probe base URL:\n'
    printf '  %s\n' "$PROBE_BASE_URL"
  fi

  if [[ "$ACTIVATE" == "true" ]]; then
    printf '\nRequested change:\n'
    printf '  Gateway inference switched to provider: %s\n' "$PROVIDER_NAME"
    printf '  Gateway inference switched to model:    %s\n' "$MODEL_NAME"
  else
    printf '\nRequested change:\n'
    printf '  Provider created or refreshed only\n'
    printf '  Active gateway inference selection was not changed by this run\n'
  fi

  print_gateway_inference_status
  print_onboarding_summary_if_available

  cat <<EOF_NEXT

Helpful follow-up:
  Script usage:              $DISPLAY_SCRIPT_PATH --help
  Show all providers:        $DISPLAY_SCRIPT_PATH --list-providers
EOF_NEXT
  print_switch_back_hint_if_available
  if [[ "$(validation_backend)" == "ollama" ]]; then
    printf '  Local model manager:     %s\n' "$DISPLAY_MODEL_MANAGER_PATH"
  fi
}

main() {
  parse_args "$@"
  resolve_defaults
  check_tooling
  check_gateway

  if [[ "$LIST_PROVIDERS" == "true" ]]; then
    log "List mode: reporting configured gateway providers"
    show_all_providers
    exit 0
  fi

  if [[ "$USE_ONBOARDING" == "true" ]]; then
    load_onboarding_selection
    validate_use_onboarding_preconditions
  fi

  if [[ "$STATUS_ONLY" == "true" ]]; then
    log "Status mode: reporting current gateway provider status only"
    show_status_summary
    exit 0
  fi

  check_endpoint
  maybe_check_model_presence
  ensure_provider_present
  maybe_activate_provider
  show_change_summary
}

main "$@"
