#!/usr/bin/env bash
set -Eeuo pipefail

# Configure OpenShell gateway inference to NVIDIA Endpoints (Nemotron).
#
# Requires:
#   - NVIDIA_API_KEY exported in your shell
#   - API key can be created at: https://build.nvidia.com
#
# Default behavior:
#   - Create/refresh provider "nvidia-prod"
#   - Use base URL: https://integrate.api.nvidia.com/v1
#   - Activate model: nvidia/nemotron-3-super-120b-a12b

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SCRIPT="${CONFIG_SCRIPT:-$SCRIPT_DIR/configure-gateway-provider.sh}"

PROVIDER_NAME="${PROVIDER_NAME:-nvidia-prod}"
BASE_URL="${BASE_URL:-https://integrate.api.nvidia.com/v1}"
MODEL_NAME="${MODEL_NAME:-nvidia/nemotron-3-super-120b-a12b}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF_USAGE'
Usage:
  ./providers/configure-nvidia-nemotron.sh
  ./providers/configure-nvidia-nemotron.sh --status
  ./providers/configure-nvidia-nemotron.sh --list-providers
  ./providers/configure-nvidia-nemotron.sh [extra configure-gateway-provider args...]

Required environment:
  NVIDIA_API_KEY   API key from https://build.nvidia.com

Defaults:
  provider-name: nvidia-prod
  base-url:      https://integrate.api.nvidia.com/v1
  model:         nvidia/nemotron-3-super-120b-a12b
EOF_USAGE
}

[[ -x "$CONFIG_SCRIPT" ]] || die "configure-gateway-provider.sh not found or not executable: $CONFIG_SCRIPT"

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

config_args=(
  --provider-name "$PROVIDER_NAME"
  --provider-type nvidia
  --base-url "$BASE_URL"
)

if [[ "${1:-}" == "--status" || "${1:-}" == "--list-providers" ]]; then
  exec "$CONFIG_SCRIPT" "${config_args[@]}" "$@"
fi

[[ -n "${NVIDIA_API_KEY:-}" ]] || die "NVIDIA_API_KEY is not set. Export your key from https://build.nvidia.com first."

log "Configuring NVIDIA Endpoints provider and activating Nemotron model"
config_args+=(
  --api-key "$NVIDIA_API_KEY"
  --model "$MODEL_NAME"
  --activate
)

exec "$CONFIG_SCRIPT" "${config_args[@]}" "$@"
