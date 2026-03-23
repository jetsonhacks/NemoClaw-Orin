#!/usr/bin/env bash
set -Eeuo pipefail

# Create or refresh an OpenShell provider for a local vLLM server.
#
# Intended usage:
#   1. Run AFTER `nemoclaw onboard`
#   2. Create the provider record for a host-backed local vLLM endpoint
#   3. Optionally activate it for inference.local by supplying MODEL_NAME
#
# Default behavior:
#   - creates/recreates the provider
#   - does NOT switch inference.local unless MODEL_NAME is set
#
# Example:
#   ./configure-provider-vllm-local.sh
#   MODEL_NAME='meta-llama/Llama-3.2-3B-Instruct' ./configure-provider-vllm-local.sh
#   VLLM_HOST_CHECK_URL='http://127.0.0.1:8000/v1/models' MODEL_NAME='my-model' ./configure-provider-vllm-local.sh

PROVIDER_NAME="${PROVIDER_NAME:-vllm-local}"
PROVIDER_TYPE="${PROVIDER_TYPE:-openai}"
OPENAI_BASE_URL="${OPENAI_BASE_URL:-http://host.openshell.internal:8000/v1}"
OPENAI_API_KEY_VALUE="${OPENAI_API_KEY_VALUE:-empty}"
VLLM_HOST_CHECK_URL="${VLLM_HOST_CHECK_URL:-http://127.0.0.1:8000/v1/models}"
FORCE_RECREATE_PROVIDER="${FORCE_RECREATE_PROVIDER:-true}"
ACTIVATE="${ACTIVATE:-false}"
MODEL_NAME="${MODEL_NAME:-}"
INFERENCE_NO_VERIFY="${INFERENCE_NO_VERIFY:-false}"
SKIP_VLLM_HOST_CHECK="${SKIP_VLLM_HOST_CHECK:-false}"
SKIP_MODEL_PRESENCE_CHECK="${SKIP_MODEL_PRESENCE_CHECK:-false}"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

check_tooling() {
  need_cmd openshell
  need_cmd curl
  need_cmd python3
}

check_gateway() {
  log "Checking OpenShell gateway state"
  openshell status >/dev/null 2>&1 || die "OpenShell gateway is not reachable. Run NemoClaw onboarding first and confirm the gateway is up."
}

check_vllm_host() {
  if [[ "$SKIP_VLLM_HOST_CHECK" == "true" ]]; then
    warn "Skipping vLLM host endpoint check (SKIP_VLLM_HOST_CHECK=true)."
    return 0
  fi

  log "Checking host vLLM endpoint"
  curl --silent --show-error --fail "$VLLM_HOST_CHECK_URL" >/tmp/vllm-models.json || \
    die "Cannot reach vLLM at $VLLM_HOST_CHECK_URL. Make sure vLLM is running on the host and listening on port 8000."
}

maybe_check_model_presence() {
  if [[ -z "$MODEL_NAME" ]]; then
    return 0
  fi

  if [[ "$SKIP_MODEL_PRESENCE_CHECK" == "true" ]]; then
    warn "Skipping model presence check (SKIP_MODEL_PRESENCE_CHECK=true)."
    return 0
  fi

  if [[ ! -f /tmp/vllm-models.json ]]; then
    check_vllm_host
  fi

  log "Checking that the requested model exists in vLLM"
  python3 - "$MODEL_NAME" /tmp/vllm-models.json <<'PY'
import json
import sys
model = sys.argv[1]
path = sys.argv[2]
with open(path) as f:
    data = json.load(f)
models = {m.get('id') for m in data.get('data', []) if isinstance(m, dict)}
if model not in models:
    raise SystemExit(f"Model not present in local vLLM catalog: {model}")
print(f"Found model in vLLM catalog: {model}")
PY
}

remove_provider_if_requested() {
  if [[ "$FORCE_RECREATE_PROVIDER" != "true" ]]; then
    return 0
  fi

  if openshell provider get "$PROVIDER_NAME" >/dev/null 2>&1; then
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

maybe_activate_provider() {
  if [[ "$ACTIVATE" != "true" && -z "$MODEL_NAME" ]]; then
    log "Provider created but inference.local was not switched"
    return 0
  fi

  [[ -n "$MODEL_NAME" ]] || die "MODEL_NAME must be set when ACTIVATE=true."

  log "Switching inference.local to provider '$PROVIDER_NAME' with model '$MODEL_NAME'"
  if [[ "$INFERENCE_NO_VERIFY" == "true" ]]; then
    openshell inference set --provider "$PROVIDER_NAME" --model "$MODEL_NAME" --no-verify
  else
    openshell inference set --provider "$PROVIDER_NAME" --model "$MODEL_NAME"
  fi
}

show_summary() {
  cat <<EOF_SUMMARY

vLLM provider configuration complete.

Provider name:
  $PROVIDER_NAME

Provider base URL:
  $OPENAI_BASE_URL

Current gateway inference configuration:
EOF_SUMMARY
  openshell inference get || true

  cat <<EOF_NEXT

Common follow-up commands:
  openshell provider list
  openshell provider get $PROVIDER_NAME
  openshell inference get

To switch inference.local to this provider later:
  openshell inference set --provider $PROVIDER_NAME --model '<vllm-model-id>'

From inside a sandbox, agent code should call:
  https://inference.local/v1

EOF_NEXT
}

main() {
  check_tooling
  check_gateway
  check_vllm_host
  maybe_check_model_presence
  remove_provider_if_requested
  create_provider
  maybe_activate_provider
  show_summary
}

main "$@"
