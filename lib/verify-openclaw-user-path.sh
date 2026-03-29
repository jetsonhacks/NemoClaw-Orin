#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/script-ui.sh"

SANDBOX_NAME=""
FORMAT="json"
QUIET="${QUIET:-false}"
VERBOSE="${VERBOSE:-false}"
DEBUG="${DEBUG:-false}"

GATEWAY_NAME="${GATEWAY_NAME:-nemoclaw}"
RUNTIME_PORT="${RUNTIME_PORT:-18789}"

usage() {
  cat <<'EOF_USAGE'
Usage:
  ./verify-openclaw-user-path.sh <sandbox-name> [flags]

Flags:
  --format json|text   Output format (default: json)
  --quiet
  --verbose
  --debug
EOF_USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --format)
        [[ $# -ge 2 ]] || die "Missing value for --format"
        case "$2" in
          json|text) FORMAT="$2" ;;
          *) die "Unsupported format: $2" ;;
        esac
        shift 2
        ;;
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
        if [[ -z "$SANDBOX_NAME" ]]; then
          SANDBOX_NAME="$1"
        else
          die "Unexpected extra argument: $1"
        fi
        shift
        ;;
    esac
  done

  [[ -n "$SANDBOX_NAME" ]] || die "Usage: $0 <sandbox-name>"
}

sandbox_ssh_command() {
  local sandbox_name="$1"
  shift
  local cmd="$*"
  local openshell_bin
  openshell_bin="$(command -v openshell)"
  ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o "ProxyCommand=${openshell_bin} ssh-proxy --gateway-name ${GATEWAY_NAME} --name ${sandbox_name}" \
    "sandbox@openshell-${sandbox_name}" \
    "${cmd}"
}

ssh_env_prefix() {
  cat <<'EOF_ENV'
export HOME=/sandbox;
EOF_ENV
}

capture_command() {
  local __outvar="$1"
  shift

  local output=""
  local rc=0
  set +e
  output="$("$@" 2>&1)"
  rc=$?
  set -e

  printf -v "$__outvar" '%s' "$output"
  return "$rc"
}

ssh_runtime_listening() {
  sandbox_ssh_command "$SANDBOX_NAME" "
    $(ssh_env_prefix)
    grep -qi ':$(printf '%04X' "$RUNTIME_PORT")' /proc/net/tcp /proc/net/tcp6
  " >/dev/null 2>&1
}

probe_gateway_in_ssh_context() {
  sandbox_ssh_command "$SANDBOX_NAME" "
    $(ssh_env_prefix)
    openclaw gateway health
  " 2>&1
}

health_probe_is_expected_prepair() {
  local probe_output="$1"
  printf '%s\n' "$probe_output" | grep -Eiq \
    'pair(ing)? required|not paired|unauthori[sz]ed|forbidden|auth(entication|orization)?.*required|pending'
}

emit_json_result() {
  local listener_up="$1"
  local gateway_health_reachable="$2"
  local user_path_ready="$3"
  local health_state="$4"

  python3 - <<PY
import json
print(json.dumps({
  "ok": True,
  "listener_up": True if "${listener_up}" == "true" else False,
  "gateway_health_reachable": True if "${gateway_health_reachable}" == "true" else False,
  "user_path_ready": True if "${user_path_ready}" == "true" else False,
  "health_state": "${health_state}"
}, indent=2))
PY
}

emit_text_result() {
  local listener_up="$1"
  local gateway_health_reachable="$2"
  local user_path_ready="$3"
  local health_state="$4"

  if [[ "$user_path_ready" == "true" ]]; then
    echo "User-facing recovery path is ready"
    echo "OpenClaw listener is up in the user-facing context"
    echo "Gateway health probe succeeded"
    return 0
  fi

  echo "User-facing recovery path is not ready"
  case "$health_state" in
    prepair_pending)
      echo "Pairing repair is still required"
      ;;
    listener_not_up)
      echo "OpenClaw listener is not up in the user-facing context"
      ;;
    health_unreachable)
      echo "Gateway health probe did not succeed"
      ;;
    *)
      echo "Run again with --debug for engineering diagnostics"
      ;;
  esac
}

main() {
  parse_args "$@"

  need_cmd openshell
  need_cmd ssh
  need_cmd grep
  need_cmd python3

  local listener_up="false"
  local gateway_health_reachable="false"
  local user_path_ready="false"
  local health_state="unknown"
  local probe_output=""

  if ssh_runtime_listening; then
    listener_up="true"
  else
    health_state="listener_not_up"
  fi

  if [[ "$listener_up" == "true" ]]; then
    if capture_command probe_output probe_gateway_in_ssh_context; then
      gateway_health_reachable="true"
      user_path_ready="true"
      health_state="healthy"
    else
      if health_probe_is_expected_prepair "$probe_output"; then
        gateway_health_reachable="true"
        user_path_ready="false"
        health_state="prepair_pending"
      else
        gateway_health_reachable="false"
        user_path_ready="false"
        health_state="health_unreachable"
      fi
    fi
  fi

  if [[ "$DEBUG" == "true" && -n "$probe_output" ]]; then
    printf '%s\n' "$probe_output" >&2
  fi

  case "$FORMAT" in
    json)
      emit_json_result "$listener_up" "$gateway_health_reachable" "$user_path_ready" "$health_state"
      ;;
    text)
      emit_text_result "$listener_up" "$gateway_health_reachable" "$user_path_ready" "$health_state"
      ;;
    *)
      die "Unsupported format: $FORMAT"
      ;;
  esac

  [[ "$user_path_ready" == "true" ]]
}

main "$@"