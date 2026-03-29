#!/usr/bin/env bash

GATEWAY_NAME="${GATEWAY_NAME:-nemoclaw}"
CONTAINER_NAME="${CONTAINER_NAME:-openshell-cluster-${GATEWAY_NAME}}"
SANDBOX_NAMESPACE="${SANDBOX_NAMESPACE:-openshell}"

QUIET="${QUIET:-false}"
VERBOSE="${VERBOSE:-false}"
DEBUG="${DEBUG:-false}"
REDACT="${REDACT:-true}"

is_quiet() {
  [[ "${QUIET}" == "true" ]]
}

is_verbose() {
  [[ "${VERBOSE}" == "true" ]]
}

is_debug() {
  [[ "${DEBUG}" == "true" ]]
}

ui_step() {
  is_quiet && return 0
  printf '\n==> %s\n' "$*"
}

ui_info() {
  is_quiet && return 0
  printf '%s\n' "$*"
}

ui_warn() {
  is_quiet && return 0
  printf '\n[WARN] %s\n' "$*" >&2
}

ui_error() {
  printf '\n[ERROR] %s\n' "$*" >&2
}

die() {
  ui_error "$*"
  return 1 2>/dev/null || exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_container() {
  docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME" \
    || die "Container '$CONTAINER_NAME' not found."
}

require_running_container() {
  require_container || return 1

  local state
  state="$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  [[ "$state" == "running" ]] || die "Container '$CONTAINER_NAME' is not running. Run ./restart-nemoclaw.sh first."
}

redact_value() {
  local value="${1:-}"

  if [[ "${REDACT}" != "true" ]]; then
    printf '%s\n' "$value"
    return 0
  fi

  if [[ -z "$value" ]]; then
    printf '<unknown>\n'
    return 0
  fi

  if [[ ${#value} -le 8 ]]; then
    printf '<redacted>\n'
    return 0
  fi

  printf '…%s\n' "${value: -8}"
}