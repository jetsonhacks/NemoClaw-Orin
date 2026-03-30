#!/usr/bin/env bash
set -euo pipefail

#
# configure-provider-openai-lan.sh
#
# Configure OpenShell to use an OpenAI-compatible model server
# running on another machine on the local network.
#
# Examples:
#   ./providers/configure-provider-openai-lan.sh --host 192.168.1.50 --port 11434 --model llama3.2:3b
#   ./providers/configure-provider-openai-lan.sh --host llm-box.local --port 8000 --model Qwen/Qwen3-8B --api-key sk-xxxx
#   ./providers/configure-provider-openai-lan.sh --host 192.168.1.50 --port 11434 --status
#
# Notes:
# - The remote server must be reachable from the Jetson over the LAN.
# - The remote server must expose an OpenAI-compatible API at /v1
# - If no API key is required, a dummy key is used.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROVIDER_NAME="lan-openai"
HOST=""
PORT=""
MODEL=""
API_KEY="${OPENAI_API_KEY:-not-needed}"
STATUS_ONLY=0
NO_VERIFY=0
SCHEME="http"
PATH_SUFFIX="/v1"

usage() {
  cat <<EOF
Usage:
  $0 --host <hostname-or-ip> --port <port> --model <model-name> [options]

Required:
  --host <host>         Remote machine hostname or IP address
  --port <port>         Remote server port
  --model <model>       Model name to select for gateway inference

Options:
  --provider-name <n>   Provider name to create/use (default: ${PROVIDER_NAME})
  --api-key <key>       API key for the remote server (default: OPENAI_API_KEY env or 'not-needed')
  --scheme <scheme>     URL scheme: http or https (default: ${SCHEME})
  --path <suffix>       API path suffix (default: ${PATH_SUFFIX})
  --no-verify           Pass --no-verify to 'openshell inference set'
  --status              Show current status only
  -h, --help            Show this help

Examples:
  $0 --host 192.168.1.50 --port 11434 --model llama3.2:3b
  $0 --host llm-box.local --port 8000 --model Qwen/Qwen3-8B --api-key sk-xxxx
  $0 --host 192.168.1.50 --port 11434 --status
EOF
}

log_step() {
  echo
  echo "==> $*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      HOST="${2:-}"
      shift 2
      ;;
    --port)
      PORT="${2:-}"
      shift 2
      ;;
    --model)
      MODEL="${2:-}"
      shift 2
      ;;
    --provider-name)
      PROVIDER_NAME="${2:-}"
      shift 2
      ;;
    --api-key)
      API_KEY="${2:-}"
      shift 2
      ;;
    --scheme)
      SCHEME="${2:-}"
      shift 2
      ;;
    --path)
      PATH_SUFFIX="${2:-}"
      shift 2
      ;;
    --status)
      STATUS_ONLY=1
      shift
      ;;
    --no-verify)
      NO_VERIFY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

need_cmd openshell

if [[ -z "${HOST}" ]]; then
  die "--host is required"
fi

if [[ -z "${PORT}" ]]; then
  die "--port is required"
fi

BASE_URL="${SCHEME}://${HOST}:${PORT}${PATH_SUFFIX}"

log_step "Checking OpenShell gateway state"
if ! openshell gateway status >/dev/null 2>&1; then
  die "OpenShell gateway is not running or not reachable"
fi

log_step "Checking remote endpoint from the Jetson"
if command -v curl >/dev/null 2>&1; then
  if ! curl --silent --show-error --max-time 5 "${BASE_URL}/models" >/dev/null 2>&1; then
    echo "Warning: could not verify ${BASE_URL}/models from the Jetson with curl"
    echo "The endpoint may still work if verification is blocked or the server behaves differently."
  fi
else
  echo "Warning: curl not found; skipping direct endpoint probe from host"
fi

log_step "Status mode: reporting current LAN provider status only"
if [[ "${STATUS_ONLY}" -eq 1 ]]; then
  echo
  echo "LAN provider status"
  echo
  echo "Provider name:"
  echo "  ${PROVIDER_NAME}"
  echo
  echo "Provider base URL:"
  echo "  ${BASE_URL}"
  echo
  if openshell provider get "${PROVIDER_NAME}" >/dev/null 2>&1; then
    echo "Provider definition:"
    echo "  Present"
  else
    echo "Provider definition:"
    echo "  Not present"
  fi
  echo
  echo "Current gateway inference:"
  openshell inference get || true
  echo
  echo "Helpful follow-up:"
  echo "  Re-run without --status to create/update the provider and select the model"
  exit 0
fi

log_step "Creating or updating provider '${PROVIDER_NAME}'"

if openshell provider get "${PROVIDER_NAME}" >/dev/null 2>&1; then
  echo "Provider already exists, replacing it"
  openshell provider delete "${PROVIDER_NAME}" >/dev/null 2>&1 || true
fi

openshell provider create \
  --name "${PROVIDER_NAME}" \
  --type openai \
  --credential "OPENAI_API_KEY=${API_KEY}" \
  --config "OPENAI_BASE_URL=${BASE_URL}"

log_step "Selecting gateway inference model"
INFERENCE_ARGS=(
  inference set
  --provider "${PROVIDER_NAME}"
  --model "${MODEL}"
)

if [[ "${NO_VERIFY}" -eq 1 ]]; then
  INFERENCE_ARGS+=(--no-verify)
fi

openshell "${INFERENCE_ARGS[@]}"

log_step "Current gateway inference"
openshell inference get

echo
echo "Done."
echo
echo "Provider name: ${PROVIDER_NAME}"
echo "Base URL:      ${BASE_URL}"
echo "Model:         ${MODEL}"