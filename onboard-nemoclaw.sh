#!/usr/bin/env bash
set -Eeuo pipefail

# Run NemoClaw onboarding in a more controlled way.
# Assumes setup-jetson-orin.sh has already been run.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPONENT_VERSIONS_PATH="${COMPONENT_VERSIONS_PATH:-$SCRIPT_DIR/lib/component-versions.sh}"
[[ -f "$COMPONENT_VERSIONS_PATH" ]] || {
  printf '\n[ERROR] Missing component versions file: %s\n' "$COMPONENT_VERSIONS_PATH" >&2
  exit 1
}
# shellcheck disable=SC1090
source "$COMPONENT_VERSIONS_PATH"

ENV_FILE="${ENV_FILE:-$HOME/.config/openshell/jetson-orin.env}"
OPEN_SHELL_CLUSTER_IMAGE_DEFAULT="${OPEN_SHELL_CLUSTER_IMAGE_DEFAULT:-ghcr.io/nvidia/openshell/cluster:${OPEN_SHELL_VERSION_PIN}}"
ONBOARD_SESSION_PATH="${ONBOARD_SESSION_PATH:-$HOME/.nemoclaw/onboard-session.json}"
FREE_PORT_CHECK_ONLY="${FREE_PORT_CHECK_ONLY:-false}"
INFERENCE_TIMEOUT_SECONDS="${INFERENCE_TIMEOUT_SECONDS:-120}"
STOP_HOST_K3S="${STOP_HOST_K3S:-true}"
REQUIRE_NODE_MAJOR="${REQUIRE_NODE_MAJOR:-22}"
MIN_SWAP_GB="${MIN_SWAP_GB:-8}"

log() { printf '\n==> %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

json_get() {
  local json_input="$1"
  local expr="$2"
  JSON_INPUT="$json_input" JSON_EXPR="$expr" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
expr = os.environ["JSON_EXPR"]

value = data
for part in expr.split("."):
    if isinstance(value, dict):
        value = value.get(part)
    else:
        value = None
        break

if value is True:
    print("true")
elif value is False:
    print("false")
elif value is None:
    print("")
else:
    print(value)
PY
}

gateway_is_healthy() {
  local status_output named_info active_info
  status_output="$(openshell status 2>/dev/null || true)"
  named_info="$(openshell gateway info -g nemoclaw 2>/dev/null || true)"
  active_info="$(openshell gateway info 2>/dev/null || true)"

  [[ "$status_output" == *"Connected"* ]] || return 1
  [[ "$named_info" == *"nemoclaw"* ]] || return 1
  [[ "$active_info" == *"nemoclaw"* ]] || return 1
}

source_env_file() {
  if [[ -f "$HOME/.bashrc" ]]; then
    # shellcheck disable=SC1090
    source "$HOME/.bashrc" || true
  fi

  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  fi

  export OPENSHELL_CLUSTER_IMAGE="${OPENSHELL_CLUSTER_IMAGE:-$OPEN_SHELL_CLUSTER_IMAGE_DEFAULT}"
}

check_tooling() {
  need_cmd docker
  need_cmd openshell
  need_cmd nemoclaw
  need_cmd node
  need_cmd npm
  need_cmd python3
  need_cmd ssh
  need_cmd sudo

  docker info >/dev/null 2>&1 || die "Docker daemon is not running or not accessible."

  local node_major
  node_major="$(node -p 'process.versions.node.split(".")[0]')"
  [[ "$node_major" =~ ^[0-9]+$ ]] || die "Unable to determine Node.js major version."
  (( node_major == REQUIRE_NODE_MAJOR )) || die "Node.js major version $REQUIRE_NODE_MAJOR is required; found $(node --version)."
}

show_resource_state() {
  log "Current memory and swap"
  free -h
  swapon --show || true

  local swap_gb
  swap_gb="$(swapon --bytes --noheadings --show=SIZE 2>/dev/null | awk '{sum += $1} END {printf "%.2f", sum/1024/1024/1024}')"
  if [[ -n "$swap_gb" ]] && awk "BEGIN {exit !($swap_gb < $MIN_SWAP_GB)}"; then
    warn "Total swap appears below ${MIN_SWAP_GB} GiB. NemoClaw docs warn that sandbox image push/import can trigger OOM on low-memory systems."
  fi
}

maybe_stop_host_k3s() {
  if [[ "$STOP_HOST_K3S" != "true" ]]; then
    warn "Leaving host k3s running (STOP_HOST_K3S=$STOP_HOST_K3S)."
    return 0
  fi

  if systemctl is-active --quiet k3s; then
    log "Stopping host k3s to reduce memory pressure during onboarding"
    sudo systemctl stop k3s
  else
    log "Host k3s is already stopped"
  fi
}

free_conflicting_ports() {
  log "Cleaning up any previous NemoClaw/OpenShell session"
  openshell forward stop 18789 2>/dev/null || true
  openshell gateway stop -g nemoclaw 2>/dev/null || true
  openshell gateway stop -g openshell 2>/dev/null || true

  log "Checking required ports"
  sudo lsof -i :8080 -sTCP:LISTEN || true
  sudo lsof -i :18789 -sTCP:LISTEN || true

  if [[ "$FREE_PORT_CHECK_ONLY" == "true" ]]; then
    log "FREE_PORT_CHECK_ONLY=true; stopping before onboarding"
    exit 0
  fi
}

check_openshell_image() {
  log "Using OpenShell cluster image"
  printf 'OPENSHELL_CLUSTER_IMAGE=%s\n' "$OPENSHELL_CLUSTER_IMAGE"
  docker image inspect "$OPENSHELL_CLUSTER_IMAGE" >/dev/null 2>&1 || \
    docker pull "$OPENSHELL_CLUSTER_IMAGE" >/dev/null || \
    die "OpenShell cluster image is not available: $OPENSHELL_CLUSTER_IMAGE"
}

verify_cluster_image_networking() {
  log "Verifying cluster image networking compatibility"
  docker run --rm --entrypoint sh "$OPENSHELL_CLUSTER_IMAGE" -lc 'iptables --version' || \
    die "Could not inspect iptables inside OpenShell cluster image: $OPENSHELL_CLUSTER_IMAGE"
}

ensure_gateway_running() {
  if gateway_is_healthy; then
    log "Reusing existing healthy OpenShell gateway"
    openshell gateway select nemoclaw >/dev/null 2>&1 || true
    return 0
  fi

  log "Starting OpenShell gateway"
  OPENSHELL_CLUSTER_IMAGE="$OPENSHELL_CLUSTER_IMAGE" openshell gateway start --name nemoclaw

  log "Selecting OpenShell gateway"
  openshell gateway select nemoclaw
}

run_onboarding() {
  log "Starting NemoClaw onboarding"
  log "OpenShell/NemoClaw will inherit OPENSHELL_CLUSTER_IMAGE from this shell"
  nemoclaw onboard
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

with open(sys.argv[1]) as f:
    data = json.load(f)

print(data.get('provider') or '')
print(data.get('model') or '')
PY
}

get_onboarding_sandbox_name() {
  if [[ ! -f "$ONBOARD_SESSION_PATH" ]]; then
    return 0
  fi

  python3 - "$ONBOARD_SESSION_PATH" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    data = json.load(f)

print(data.get('sandboxName') or '')
PY
}

ensure_cli_pairing() {
  local sandbox_name pairing_json pairing_rc action error_message

  sandbox_name="$(get_onboarding_sandbox_name)"
  if [[ -z "$sandbox_name" ]]; then
    warn "Could not determine sandbox name from $ONBOARD_SESSION_PATH; skipping CLI pairing approval."
    warn "Run manually: ./lib/apply-openclaw-cli-approval.sh <sandbox-name> --format text"
    return 0
  fi

  log "Ensuring CLI pairing approval for sandbox '${sandbox_name}'"

  pairing_rc=0
  pairing_json="$("$SCRIPT_DIR/lib/apply-openclaw-cli-approval.sh" "$sandbox_name" --format json --quiet)" || pairing_rc=$?

  if [[ $pairing_rc -ne 0 ]]; then
    error_message="$(json_get "$pairing_json" "error" 2>/dev/null || true)"
    warn "Automatic CLI pairing approval failed for sandbox '${sandbox_name}'."
    [[ -n "$error_message" ]] && warn "$error_message"
    warn "Run manually: ./lib/apply-openclaw-cli-approval.sh ${sandbox_name} --format text"
    return 0
  fi

  action="$(json_get "$pairing_json" "action" 2>/dev/null || true)"
  case "$action" in
    applied_cli_approve_request_id)
      log "CLI pairing approval applied"
      ;;
    noop_already_paired)
      log "CLI pairing approval not needed"
      ;;
    *)
      warn "Automatic CLI pairing approval did not reach a healthy terminal state (action: ${action:-unknown})."
      warn "Run manually: ./lib/apply-openclaw-cli-approval.sh ${sandbox_name} --format text"
      ;;
  esac
}

ensure_inference_ready() {
  local -a active_pm=() onboarding_pm=()
  local active_provider active_model onboarding_provider onboarding_model

  mapfile -t active_pm < <(get_active_provider_and_model)
  active_provider="${active_pm[0]:-}"
  active_model="${active_pm[1]:-}"

  if [[ -n "$active_provider" && -n "$active_model" ]]; then
    log "Gateway inference is ready"
    printf 'Provider: %s\n' "$active_provider"
    printf 'Model:    %s\n' "$active_model"
    return 0
  fi

  warn "Gateway inference is not fully configured after onboarding."

  mapfile -t onboarding_pm < <(get_onboarding_provider_and_model)
  onboarding_provider="${onboarding_pm[0]:-}"
  onboarding_model="${onboarding_pm[1]:-}"

  if [[ -n "$onboarding_provider" && -n "$onboarding_model" ]] && openshell provider get "$onboarding_provider" >/dev/null 2>&1; then
    log "Restoring the onboarding provider selection"
    openshell inference set --provider "$onboarding_provider" --model "$onboarding_model" --no-verify || \
      warn "Could not restore onboarding inference selection automatically."

    mapfile -t active_pm < <(get_active_provider_and_model)
    active_provider="${active_pm[0]:-}"
    active_model="${active_pm[1]:-}"
  fi

  if [[ -n "$active_provider" && -n "$active_model" ]]; then
    log "Gateway inference is ready"
    printf 'Provider: %s\n' "$active_provider"
    printf 'Model:    %s\n' "$active_model"
    return 0
  fi

  warn "The assistant may not answer until gateway inference is configured."
  if [[ -n "$onboarding_provider" && -n "$onboarding_model" ]]; then
    printf '\nTry:\n'
    printf '  openshell inference set --provider %q --model %q --no-verify\n' "$onboarding_provider" "$onboarding_model"
  else
    printf '\nTry:\n'
    printf '  ./providers/configure-gateway-provider.sh --status\n'
    printf '  ./providers/configure-ollama-local.sh --model <model-name>\n'
  fi
}

ensure_inference_timeout() {
  local -a active_pm=()
  local active_provider active_model

  mapfile -t active_pm < <(get_active_provider_and_model)
  active_provider="${active_pm[0]:-}"
  active_model="${active_pm[1]:-}"

  if [[ -z "$active_provider" || -z "$active_model" ]]; then
    warn "Could not determine active provider/model; skipping inference timeout configuration."
    return 0
  fi

  log "Setting inference timeout to ${INFERENCE_TIMEOUT_SECONDS}s"
  openshell inference set \
    --timeout "$INFERENCE_TIMEOUT_SECONDS" \
    --provider "$active_provider" \
    --model "$active_model" \
    --no-verify || \
    warn "Could not set inference timeout. Run manually: openshell inference set --timeout ${INFERENCE_TIMEOUT_SECONDS} --provider ${active_provider} --model ${active_model} --no-verify"
}

print_recovery_hints() {
  cat <<'EOF_HINTS'

If onboarding fails:

  dmesg -T | grep -i -E 'killed process|out of memory|oom'
  free -h
  swapon --show
  docker ps -a
  openshell status || true

EOF_HINTS
}

main() {
  source_env_file
  check_tooling
  show_resource_state
  maybe_stop_host_k3s
  free_conflicting_ports
  check_openshell_image
  verify_cluster_image_networking
  ensure_gateway_running
  print_recovery_hints
  run_onboarding
  ensure_cli_pairing
  ensure_inference_ready
  ensure_inference_timeout
}

main "$@"
