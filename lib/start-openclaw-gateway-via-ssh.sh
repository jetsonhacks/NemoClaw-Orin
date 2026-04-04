#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$ROOT_DIR/lib/script-ui.sh"
source "$ROOT_DIR/lib/sandbox-kexec.sh"
source "$ROOT_DIR/lib/openclaw-user-path.sh"

RESTART_SCRIPT="${RESTART_SCRIPT:-$ROOT_DIR/restart-nemoclaw.sh}"

SANDBOX_NAME=""
FORMAT="text"
QUIET="${QUIET:-false}"
VERBOSE="${VERBOSE:-false}"
DEBUG="${DEBUG:-false}"
SKIP_RESTART="${SKIP_RESTART:-false}"

GATEWAY_NAME="${GATEWAY_NAME:-nemoclaw}"
SANDBOX_NAMESPACE="${SANDBOX_NAMESPACE:-openshell}"
RUNTIME_PORT="${RUNTIME_PORT:-18789}"
START_TIMEOUT="${START_TIMEOUT:-60}"
POD_READY_TIMEOUT="${POD_READY_TIMEOUT:-120}"
OPENCLAW_GATEWAY_ARGS="${OPENCLAW_GATEWAY_ARGS:-run --port ${RUNTIME_PORT}}"

usage() {
  cat <<'EOF'
Usage:
  lib/start-openclaw-gateway-via-ssh.sh <sandbox-name> [flags]

Flags:
  --format json|text   Output format (default: text)
  --quiet
  --verbose
  --debug
  --skip-restart       Do not run outer restart first
  --timeout <seconds>  Listener wait timeout (default: 60)
EOF
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
      --skip-restart)
        SKIP_RESTART="true"
        shift
        ;;
      --timeout)
        [[ $# -ge 2 ]] || die "Missing value for --timeout"
        START_TIMEOUT="$2"
        shift 2
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

kctl() {
  docker exec "$CONTAINER_NAME" kubectl "$@" 2>/dev/null
}

debug_stderr() {
  if [[ "$DEBUG" == "true" ]]; then
    printf '%s\n' "$*" >&2
  fi
}

wait_for_sandbox_ready() {
  local elapsed=0
  local interval=5

  while [[ $elapsed -lt $POD_READY_TIMEOUT ]]; do
    local pod_line ready_col
    pod_line="$(kctl get pod -n "$SANDBOX_NAMESPACE" "$SANDBOX_NAME" --no-headers 2>/dev/null)" || true
    ready_col="$(printf '%s\n' "$pod_line" | awk '{print $2}')"

    if [[ "$ready_col" == "1/1" ]]; then
      return 0
    fi

    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  return 1
}

fix_ownership_host_side() {
  docker exec "$CONTAINER_NAME" \
    kubectl exec -n "$SANDBOX_NAMESPACE" "$SANDBOX_NAME" -- \
    sh -lc 'chown -R sandbox:sandbox /sandbox/.openclaw /sandbox/.openclaw-data' >/dev/null 2>&1 || true
}

show_ssh_runtime_debug() {
  local output=""
  set +e
  output="$(openclaw_sandbox_ssh_command "$SANDBOX_NAME" "
    $(openclaw_ssh_env_prefix)
    echo '--- id / pwd / home ---'
    id || true
    pwd || true
    echo \"HOME=\$HOME\"
    echo '--- gateway command ---'
    echo 'openclaw gateway ${OPENCLAW_GATEWAY_ARGS}'
    echo '--- proxy env ---'
    env | grep -i proxy || true
    echo '--- tls / ca env ---'
    env | grep -E 'CA_BUNDLE|SSL_CERT|NODE_EXTRA_CA_CERTS' || true
    echo '--- tcp listeners for ${RUNTIME_PORT} ---'
    cat /proc/net/tcp  | grep ':$(printf '%04X' "$RUNTIME_PORT")' || true
    cat /proc/net/tcp6 | grep ':$(printf '%04X' "$RUNTIME_PORT")' || true
    echo '--- recent runtime log ---'
    ls -l /tmp/openclaw/runtime.log 2>/dev/null || true
    tail -n 200 /tmp/openclaw/runtime.log 2>/dev/null || true
    echo '--- matching gateway procs ---'
    for pid_dir in /proc/[0-9]*; do
      pid=\"\${pid_dir##*/}\"
      comm=\"\$(cat \"\$pid_dir/comm\" 2>/dev/null || true)\"
      cmdline=\"\$(tr '\0' ' ' < \"\$pid_dir/cmdline\" 2>/dev/null || true)\"
      case \"\$comm \$cmdline\" in
        openclaw-gateway*|openclaw\ *gateway*|*'exec openclaw gateway '* )
          echo \"\$pid :: \$comm :: \$cmdline\"
          ;;
      esac
    done
  " 2>&1)"
  set -e

  [[ -n "$output" ]] && printf '%s\n' "$output" >&2
  return 0
}

stop_old_gateway_in_ssh_context() {
  openclaw_sandbox_ssh_command "$SANDBOX_NAME" "
    $(openclaw_ssh_env_prefix)
    self_pid=\$$
    parent_pid=\$PPID

    for pid_dir in /proc/[0-9]*; do
      pid=\"\${pid_dir##*/}\"

      [ \"\$pid\" = \"\$self_pid\" ] && continue
      [ \"\$pid\" = \"\$parent_pid\" ] && continue

      comm=\"\$(cat \"\$pid_dir/comm\" 2>/dev/null || true)\"
      cmdline=\"\$(tr '\0' ' ' < \"\$pid_dir/cmdline\" 2>/dev/null || true)\"

      case \"\$comm\" in
        openclaw-gateway)
          kill \"\$pid\" 2>/dev/null || true
          ;;
        openclaw)
          case \"\$cmdline\" in
            *' openclaw gateway '*|openclaw\ gateway\ *|*'exec openclaw gateway '*)
              kill \"\$pid\" 2>/dev/null || true
              ;;
          esac
          ;;
      esac
    done

    sleep 1
    echo CLEANUP_DONE
  "
}

start_gateway_in_ssh_context() {
  openclaw_sandbox_ssh_command "$SANDBOX_NAME" "
    $(openclaw_ssh_env_prefix)
    mkdir -p /tmp/openclaw /sandbox/.openclaw/cron /sandbox/.openclaw-data/cron
    [ -f /sandbox/.openclaw/cron/jobs.json ] || printf '{}\n' > /sandbox/.openclaw/cron/jobs.json
    [ -f /sandbox/.openclaw-data/cron/jobs.json ] || printf '{}\n' > /sandbox/.openclaw-data/cron/jobs.json
    if [ ${DEBUG@Q} = 'true' ]; then
      echo \"Launching: openclaw gateway ${OPENCLAW_GATEWAY_ARGS}\" >&2
    fi
    nohup sh -lc 'exec openclaw gateway ${OPENCLAW_GATEWAY_ARGS}' >/tmp/openclaw/runtime.log 2>&1 &
    sleep 2
    echo START_DONE
  "
}

emit_text_result() {
  local listener_up="$1"
  local health_state="$2"
  local pairing_repair_required="$3"

  if [[ "$listener_up" != "true" ]]; then
    case "$health_state" in
      sandbox_not_ready)
        echo "Sandbox pod did not become ready"
        ;;
      forward_failed)
        echo "Failed to establish port forwarding to the sandbox"
        ;;
      ssh_start_failed)
        echo "Failed while starting the OpenClaw gateway in the SSH context"
        ;;
      listener_not_up)
        echo "Inner OpenClaw gateway did not start in the user-facing context"
        ;;
      listener_disappeared)
        echo "Inner OpenClaw gateway listener came up, then disappeared"
        ;;
      *)
        echo "Inner OpenClaw gateway did not start in the user-facing context"
        ;;
    esac
    return 0
  fi

  echo "Started inner OpenClaw gateway in user-facing context"
  echo "Gateway listener is up"

  if [[ "$pairing_repair_required" == "true" ]]; then
    echo "Pairing repair is still required"
  else
    case "$health_state" in
      healthy)
        echo "Gateway health probe succeeded"
        ;;
      no_probe_output)
        echo "Gateway listener is up; health probe returned no output"
        ;;
      *)
        echo "Gateway listener is up"
        ;;
    esac
  fi
}

emit_json_result() {
  local ok="$1"
  local listener_up="$2"
  local health_state="$3"
  local pairing_repair_required="$4"

  python3 - <<PY
import json
print(json.dumps({
  "ok": True if "${ok}" == "true" else False,
  "listener_up": True if "${listener_up}" == "true" else False,
  "health_state": "${health_state}",
  "pairing_repair_required": True if "${pairing_repair_required}" == "true" else False
}, indent=2))
PY
}

emit_failure_and_debug() {
  local health_state="$1"
  local extra_stderr="${2:-}"

  case "$FORMAT" in
    json)
      emit_json_result "false" "false" "$health_state" "false"
      ;;
    text)
      emit_text_result "false" "$health_state" "false"
      ;;
    *)
      die "Unsupported format: $FORMAT"
      ;;
  esac

  [[ -n "$extra_stderr" ]] && printf '%s\n' "$extra_stderr" >&2
  if [[ "$DEBUG" == "true" ]]; then
    show_ssh_runtime_debug || true
  fi

  exit 1
}

main() {
  parse_args "$@"

  need_cmd docker
  need_cmd openshell
  need_cmd ssh
  need_cmd grep
  need_cmd python3

  if [[ "$SKIP_RESTART" != "true" ]]; then
    [[ -x "$RESTART_SCRIPT" ]] || die "Restart script not found or not executable: $RESTART_SCRIPT"

    if [[ "$FORMAT" == "text" ]]; then
      ui_step "Restoring outer OpenShell infrastructure"
      "$RESTART_SCRIPT"
    else
      QUIET=true "$RESTART_SCRIPT" >/dev/null 2>&1
    fi

    require_running_container
  else
    require_running_container
  fi

  wait_for_sandbox_ready || emit_failure_and_debug "sandbox_not_ready"

  if [[ "$FORMAT" == "text" && "$VERBOSE" == "true" ]]; then
    ui_info "Preparing SSH-context startup"
  fi

  debug_stderr "Gateway command: openclaw gateway ${OPENCLAW_GATEWAY_ARGS}"
  debug_stderr "Listener timeout: ${START_TIMEOUT}s"
  debug_stderr "Pod ready timeout: ${POD_READY_TIMEOUT}s"

  local verify_json=""
  if verify_json="$("$ROOT_DIR/lib/verify-openclaw-user-path.sh" "$SANDBOX_NAME" --format json --quiet 2>/dev/null)"; then
    local already_ready=""
    already_ready="$(python3 - <<'PY' "$verify_json"
import json, sys
data = json.loads(sys.argv[1])
print("true" if data.get("user_path_ready") else "false")
PY
)"
    if [[ "$already_ready" == "true" ]]; then
      if [[ "$FORMAT" == "json" ]]; then
        printf '%s\n' "$verify_json"
      else
        echo "User-facing recovery path is already ready"
        echo "OpenClaw listener is up in the user-facing context"
        echo "Gateway health probe succeeded"
      fi
      exit 0
    fi
  fi

  fix_ownership_host_side

  local stop_output=""
  if ! openclaw_capture_command stop_output stop_old_gateway_in_ssh_context; then
    [[ -n "$stop_output" ]] && printf '%s\n' "$stop_output" >&2
    if [[ "$DEBUG" == "true" ]]; then
      debug_stderr "Stale gateway cleanup did not complete; continuing with a fresh gateway start."
    fi
  fi

  local start_output=""
  if ! openclaw_capture_command start_output start_gateway_in_ssh_context; then
    emit_failure_and_debug "ssh_start_failed" "$start_output"
  fi

  local elapsed=0
  local interval=2
  local listener_up="false"

  while [[ $elapsed -lt $START_TIMEOUT ]]; do
    if openclaw_ssh_runtime_listening "$SANDBOX_NAME" "$RUNTIME_PORT"; then
      listener_up="true"
      break
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  if [[ "$listener_up" != "true" ]]; then
    emit_failure_and_debug "listener_not_up"
  fi

  local probe_output=""
  local health_state="healthy"
  local pairing_repair_required="false"

  probe_output="$(openclaw_probe_gateway_health "$SANDBOX_NAME" || true)"

  if openclaw_health_probe_is_expected_prepair "$probe_output"; then
    health_state="prepair_pending"
    pairing_repair_required="true"
  elif [[ -z "$probe_output" ]]; then
    health_state="no_probe_output"
  else
    health_state="healthy"
  fi

  sleep 5
  if ! openclaw_ssh_runtime_listening "$SANDBOX_NAME" "$RUNTIME_PORT"; then
    emit_failure_and_debug "listener_disappeared"
  fi

  if [[ "$DEBUG" == "true" && -n "$probe_output" ]]; then
    printf '%s\n' "$probe_output" >&2
  fi

  case "$FORMAT" in
    json)
      emit_json_result "true" "true" "$health_state" "$pairing_repair_required"
      ;;
    text)
      emit_text_result "true" "$health_state" "$pairing_repair_required"
      ;;
    *)
      die "Unsupported format: $FORMAT"
      ;;
  esac
}

main "$@"
