#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/script-ui.sh"
source "$ROOT_DIR/lib/openclaw-user-path.sh"

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

  if openclaw_ssh_runtime_listening "$SANDBOX_NAME" "$RUNTIME_PORT"; then
    listener_up="true"
  else
    health_state="listener_not_up"
  fi

  if [[ "$listener_up" == "true" ]]; then
    if openclaw_capture_command probe_output openclaw_probe_gateway_health "$SANDBOX_NAME"; then
      gateway_health_reachable="true"
      user_path_ready="true"
      health_state="healthy"
    else
      if openclaw_health_probe_is_expected_prepair "$probe_output"; then
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
