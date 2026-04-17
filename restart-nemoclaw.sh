#!/usr/bin/env bash
set -Eeuo pipefail

# LEGACY: retained for older JetsonHacks recovery references. Prefer upstream
# NemoClaw/OpenShell lifecycle commands for new installs.
#
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/lib/script-ui.sh"

GATEWAY_NAME="${GATEWAY_NAME:-nemoclaw}"
CONTAINER_NAME="${CONTAINER_NAME:-openshell-cluster-${GATEWAY_NAME}}"
SANDBOX_NAMESPACE="${SANDBOX_NAMESPACE:-openshell}"
ENV_FILE="${ENV_FILE:-$HOME/.config/openshell/jetson-orin.env}"
GATEWAY_READY_TIMEOUT="${GATEWAY_READY_TIMEOUT:-90}"
POD_READY_TIMEOUT="${POD_READY_TIMEOUT:-120}"

QUIET="${QUIET:-false}"
VERBOSE="${VERBOSE:-false}"
DEBUG="${DEBUG:-false}"

usage() {
  cat <<'EOF'
Usage:
  ./restart-nemoclaw.sh [flags]

Flags:
  --quiet
  --verbose
  --debug
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --quiet)
        QUIET="true"
        shift
        ;;
      --verbose)
        VERBOSE="true"
        shift
        ;;
      --debug)
        DEBUG="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        die "Unexpected argument: $1"
        ;;
    esac
  done
}

kctl() {
  docker exec "$CONTAINER_NAME" kubectl "$@" 2>/dev/null
}

source_env_file() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    if is_verbose || is_debug; then
      ui_info "Loaded OpenShell environment: $ENV_FILE"
      ui_info "OPENSHELL_CLUSTER_IMAGE=${OPENSHELL_CLUSTER_IMAGE:-<not set>}"
    fi
  else
    if is_verbose || is_debug; then
      ui_warn "Env file not found: $ENV_FILE"
      ui_warn "OPENSHELL_CLUSTER_IMAGE may not be set in this shell."
    fi
  fi
}

ensure_container_exists() {
  docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME" \
    || die "Container '$CONTAINER_NAME' not found. The gateway may have been destroyed. Run onboard-nemoclaw.sh to recreate it."
}

start_gateway_container() {
  local container_status
  container_status="$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME")"

  if [[ "$container_status" == "running" ]]; then
    if is_verbose || is_debug; then
      ui_info "Gateway container is already running."
    fi
    return 0
  fi

  docker start "$CONTAINER_NAME" >/dev/null
}

select_gateway() {
  openshell gateway select "$GATEWAY_NAME" >/dev/null 2>&1
}

wait_for_gateway_ready() {
  local elapsed=0
  local interval=5

  while [[ $elapsed -lt $GATEWAY_READY_TIMEOUT ]]; do
    if openshell status >/dev/null 2>&1; then
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  return 1
}

wait_for_pod_ready() {
  local pod_name="$1"
  local elapsed=0
  local interval=5

  while [[ $elapsed -lt $POD_READY_TIMEOUT ]]; do
    local pod_line ready_col
    pod_line="$(kctl get pod -n "$SANDBOX_NAMESPACE" "$pod_name" --no-headers 2>/dev/null)" || true
    ready_col="$(printf '%s\n' "$pod_line" | awk '{print $2}')"

    if [[ "$ready_col" == "1/1" ]]; then
      return 0
    fi

    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  return 1
}

show_debug_state() {
  if ! is_debug; then
    return 0
  fi

  echo ""
  echo "--- openshell gateway info ---"
  openshell gateway info || true

  echo ""
  echo "--- pod status ---"
  docker exec "$CONTAINER_NAME" kubectl get pod -n "$SANDBOX_NAMESPACE" -o wide || true

  echo ""
  echo "--- sandbox list ---"
  openshell sandbox list || true

  echo ""
  echo "--- nemoclaw status ---"
  nemoclaw status || true
}

main() {
  parse_args "$@"

  need_cmd docker
  need_cmd openshell

  ui_step "Loading OpenShell environment"
  source_env_file

  ui_step "Checking gateway container"
  ensure_container_exists

  ui_step "Starting gateway container"
  start_gateway_container

  ui_step "Selecting gateway '${GATEWAY_NAME}'"
  select_gateway

  ui_step "Waiting for gateway API to become ready"
  wait_for_gateway_ready \
    || die "Gateway did not become ready within ${GATEWAY_READY_TIMEOUT}s. Check: docker logs $CONTAINER_NAME"

  ui_step "Waiting for control plane pod to become ready"
  wait_for_pod_ready "openshell-0" \
    || die "openshell-0 did not become ready within ${POD_READY_TIMEOUT}s. Check: docker logs $CONTAINER_NAME"

  show_debug_state

  if ! is_quiet; then
    echo ""
    echo "OpenShell outer recovery complete."
    echo ""
    echo "Next:"
    echo "  ./recover-sandbox.sh <sandbox-name>"
    echo ""
    echo "Browser access is restored by sandbox recovery (forward-openclaw stage),"
    echo "not by outer restart alone."
  fi
}

main "$@"
