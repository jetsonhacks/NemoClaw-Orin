#!/usr/bin/env bash
set -Eeuo pipefail

# Configure OpenShell gateway inference to a local Ollama server.
#
# Default behavior:
#   - Create/refresh provider "ollama-local"
#   - Use gateway-visible base URL: http://host.openshell.internal:11434/v1
#   - Validate against host-side URL: http://127.0.0.1:11434
#   - Activate the explicitly selected model
#
# This wrapper does not install Ollama and does not pull models.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SCRIPT="${CONFIG_SCRIPT:-$SCRIPT_DIR/configure-gateway-provider.sh}"

PROVIDER_NAME="${PROVIDER_NAME:-ollama-local}"
BASE_URL="${BASE_URL:-http://host.openshell.internal:11434/v1}"
PROBE_BASE_URL="${PROBE_BASE_URL:-http://127.0.0.1:11434}"
MODEL_NAME="${MODEL_NAME:-}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF_USAGE'
Usage:
  ./providers/configure-ollama-local.sh --model <model-name>
  ./providers/configure-ollama-local.sh --status
  ./providers/configure-ollama-local.sh --list-providers
  MODEL_NAME=<model-name> ./providers/configure-ollama-local.sh
  ./providers/configure-ollama-local.sh [extra configure-gateway-provider args...]

Defaults:
  provider-name:  ollama-local
  base-url:       http://host.openshell.internal:11434/v1
  probe-base-url: http://127.0.0.1:11434

Notes:
  - This script configures the gateway to use a local Ollama server.
  - It does not install Ollama.
  - It does not pull models into Ollama.
  - Use providers/manage-ollama-models.sh first if the model is not installed yet.
EOF_USAGE
}

[[ -x "$CONFIG_SCRIPT" ]] || die "configure-gateway-provider.sh not found or not executable: $CONFIG_SCRIPT"

first_arg="${1:-}"
passthrough_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      [[ $# -ge 2 ]] || die "--model requires a value."
      MODEL_NAME="$2"
      passthrough_args+=("$1" "$2")
      shift 2
      ;;
    *)
      passthrough_args+=("$1")
      shift
      ;;
  esac
done

case "$first_arg" in
  -h|--help)
    usage
    exit 0
    ;;
esac

config_args=(
  --provider-name "$PROVIDER_NAME"
  --provider-type openai
  --backend ollama
  --base-url "$BASE_URL"
  --probe-base-url "$PROBE_BASE_URL"
  --api-key empty
)

if [[ "$first_arg" == "--status" || "$first_arg" == "--list-providers" ]]; then
  exec "$CONFIG_SCRIPT" "${config_args[@]}" "${passthrough_args[@]}"
fi

if [[ -z "$MODEL_NAME" ]]; then
  die "No Ollama model selected. Pass --model <model-name> or export MODEL_NAME first."
fi

log "Configuring local Ollama provider and activating model: $MODEL_NAME"
config_args+=(
  --model "$MODEL_NAME"
  --activate
)

exec "$CONFIG_SCRIPT" "${config_args[@]}" "${passthrough_args[@]}"
