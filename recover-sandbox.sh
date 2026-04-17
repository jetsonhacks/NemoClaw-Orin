#!/usr/bin/env bash
set -Eeuo pipefail

# LEGACY: retained for older JetsonHacks recovery references. Prefer upstream
# NemoClaw/OpenShell lifecycle commands for new installs.
#
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/lib/script-ui.sh"

SANDBOX_NAME=""
QUIET="${QUIET:-false}"
VERBOSE="${VERBOSE:-false}"
DEBUG="${DEBUG:-false}"
DRY_RUN="${DRY_RUN:-false}"
SKIP_OUTER_RESTART="${SKIP_OUTER_RESTART:-false}"
INFERENCE_TIMEOUT_SECONDS="${INFERENCE_TIMEOUT_SECONDS:-120}"

usage() {
  cat <<'EOF'
Usage:
  ./recover-sandbox.sh <sandbox-name> [flags]

Flags:
  --quiet
  --verbose
  --debug
  --dry-run
  --skip-outer-restart
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
      --dry-run)
        DRY_RUN="true"
        shift
        ;;
      --skip-outer-restart)
        SKIP_OUTER_RESTART="true"
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

json_get() {
  local json_input="$1"
  local expr="$2"
  JSON_INPUT="$json_input" JSON_EXPR="$expr" python3 - <<'PY'
import json
import os
import sys

raw = os.environ["JSON_INPUT"]
expr = os.environ["JSON_EXPR"]

try:
    data = json.loads(raw)
except Exception:
    sys.exit(2)

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

is_valid_json() {
  local json_input="$1"
  JSON_INPUT="$json_input" python3 - <<'PY'
import json
import os
import sys

try:
    json.loads(os.environ["JSON_INPUT"])
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
}

capture_command_split() {
  local __stdout_var="$1"
  local __stderr_var="$2"
  local __rc_var="$3"
  shift 3

  local stdout_file stderr_file rc
  stdout_file="$(mktemp)"
  stderr_file="$(mktemp)"
  rc=0

  set +e
  "$@" >"$stdout_file" 2>"$stderr_file"
  rc=$?
  set -e

  printf -v "$__stdout_var" '%s' "$(cat "$stdout_file")"
  printf -v "$__stderr_var" '%s' "$(cat "$stderr_file")"
  printf -v "$__rc_var" '%s' "$rc"

  rm -f "$stdout_file" "$stderr_file"
  return 0
}

run_outer_restart() {
  local args=()

  if [[ "$DEBUG" == "true" ]]; then
    args+=(--debug)
  elif [[ "$VERBOSE" == "true" ]]; then
    args+=(--verbose)
  else
    args+=(--quiet)
  fi

  "$ROOT_DIR/restart-nemoclaw.sh" "${args[@]}"
}

run_start_gateway() {
  local args=(
    "$SANDBOX_NAME"
    --format json
    --quiet
    --skip-restart
  )

  if [[ "$DEBUG" == "true" ]]; then
    args+=(--debug)
  elif [[ "$VERBOSE" == "true" ]]; then
    args+=(--verbose)
  fi

  "$ROOT_DIR/lib/start-openclaw-gateway-via-ssh.sh" "${args[@]}"
}

run_cli_map_report() {
  "$ROOT_DIR/lib/map-openclaw-cli-approval-target.sh" \
    "$SANDBOX_NAME" \
    --format json \
    --quiet
}

run_cli_apply() {
  "$ROOT_DIR/lib/apply-openclaw-cli-approval.sh" \
    "$SANDBOX_NAME" \
    --format json \
    --quiet
}

run_verify() {
  "$ROOT_DIR/lib/verify-openclaw-user-path.sh" \
    "$SANDBOX_NAME" \
    --format json \
    --quiet
}

run_forward_openclaw() {
  local args=("$SANDBOX_NAME")

  if [[ "$QUIET" == "true" ]]; then
    args+=(--quiet)
  elif [[ "$DEBUG" == "true" ]]; then
    args+=(--debug)
  elif [[ "$VERBOSE" == "true" ]]; then
    args+=(--verbose)
  fi

  "$ROOT_DIR/forward-openclaw.sh" "${args[@]}"
}

debug_report_success_path() {
  local path_name="$1"
  if [[ "$DEBUG" == "true" ]]; then
    ui_info "Successful recovery path: ${path_name}"
  fi
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

ensure_inference_timeout() {
  local -a active_pm=()
  local active_provider active_model

  mapfile -t active_pm < <(get_active_provider_and_model)
  active_provider="${active_pm[0]:-}"
  active_model="${active_pm[1]:-}"

  if [[ -z "$active_provider" || -z "$active_model" ]]; then
    ui_warn "Could not determine active provider/model; skipping inference timeout configuration."
    return 0
  fi

  ui_step "Setting inference timeout to ${INFERENCE_TIMEOUT_SECONDS}s"
  openshell inference set \
    --timeout "$INFERENCE_TIMEOUT_SECONDS" \
    --provider "$active_provider" \
    --model "$active_model" \
    --no-verify || \
    ui_warn "Could not set inference timeout. Run manually: openshell inference set --timeout ${INFERENCE_TIMEOUT_SECONDS} --provider ${active_provider} --model ${active_model} --no-verify"
}

finalize_recovery() {
  local path_name="$1"

  ensure_inference_timeout

  debug_report_success_path "$path_name"

  echo ""
  echo "Recovery complete."
  echo ""
  echo "Next:"
  echo "  nemoclaw ${SANDBOX_NAME} connect"
  echo "  openclaw tui"
}

report_start_failure() {
  local start_rc="$1"
  local start_stdout="$2"
  local start_stderr="$3"

  if [[ "$DEBUG" == "true" ]]; then
    ui_info "Gateway start helper exit code: ${start_rc}"
    if [[ -n "$start_stdout" ]]; then
      echo "--- gateway start stdout ---"
      printf '%s\n' "$start_stdout"
    fi
    if [[ -n "$start_stderr" ]]; then
      echo "--- gateway start stderr ---" >&2
      printf '%s\n' "$start_stderr" >&2
    fi
  fi

  if [[ -z "$start_stdout" ]]; then
    ui_warn "Inner OpenClaw gateway helper returned no JSON payload."
    ui_warn "Run again with --debug for engineering diagnostics."
    return 1
  fi

  if ! is_valid_json "$start_stdout"; then
    ui_warn "Inner OpenClaw gateway helper returned non-JSON output."
    ui_warn "Run again with --debug for engineering diagnostics."
    return 1
  fi

  local listener_up=""
  local health_state=""
  listener_up="$(json_get "$start_stdout" "listener_up" 2>/dev/null || true)"
  health_state="$(json_get "$start_stdout" "health_state" 2>/dev/null || true)"

  case "$health_state" in
    sandbox_not_ready)
      ui_warn "Sandbox pod did not become ready."
      ;;
    forward_failed)
      ui_warn "Failed to establish port forwarding to the sandbox."
      ;;
    ssh_start_failed)
      ui_warn "Failed while starting the OpenClaw gateway in the SSH context."
      ;;
    listener_not_up)
      ui_warn "Inner OpenClaw gateway listener did not come up in the user-facing context."
      ;;
    listener_disappeared)
      ui_warn "Inner OpenClaw gateway listener came up, then disappeared."
      ;;
    *)
      ui_warn "Inner OpenClaw gateway did not start successfully."
      ui_warn "Run again with --debug for engineering diagnostics."
      ;;
  esac

  return 1
}

main() {
  parse_args "$@"
  need_cmd docker
  need_cmd python3

  ui_step "Recovering sandbox '${SANDBOX_NAME}'"

  if [[ "$SKIP_OUTER_RESTART" != "true" ]]; then
    ui_step "Restoring outer OpenShell infrastructure"
    run_outer_restart
  else
    require_running_container
  fi

  ui_step "Starting inner OpenClaw gateway in user-facing context"
  local start_stdout="" start_stderr="" start_rc=""
  capture_command_split start_stdout start_stderr start_rc run_start_gateway

  if [[ "$start_rc" != "0" ]]; then
    report_start_failure "$start_rc" "$start_stdout" "$start_stderr"
    return 1
  fi

  if [[ "$DEBUG" == "true" ]]; then
    if [[ -n "$start_stdout" ]]; then
      echo "--- gateway start stdout ---"
      printf '%s\n' "$start_stdout"
    fi
    if [[ -n "$start_stderr" ]]; then
      echo "--- gateway start stderr ---" >&2
      printf '%s\n' "$start_stderr" >&2
    fi
  fi

  if ! is_valid_json "$start_stdout"; then
    ui_warn "Inner OpenClaw gateway helper returned non-JSON output."
    ui_warn "Run again with --debug for engineering diagnostics."
    return 1
  fi

  local listener_up
  listener_up="$(json_get "$start_stdout" "listener_up")"
  if [[ "$listener_up" != "true" ]]; then
    die "Inner OpenClaw gateway listener did not come up in the user-facing context."
  fi

  ui_step "Verifying user-facing path"
  local verify_json
  verify_json="$(run_verify)"
  if [[ "$DEBUG" == "true" ]]; then
    printf '%s\n' "$verify_json"
  fi

  local user_path_ready
  local health_state
  user_path_ready="$(json_get "$verify_json" "user_path_ready")"
  health_state="$(json_get "$verify_json" "health_state")"

  if [[ "$user_path_ready" == "true" ]]; then
    ui_step "Ensuring OpenClaw browser forward"
    run_forward_openclaw || {
      ui_warn "Sandbox recovery succeeded, but browser forward could not be confirmed."
      ui_warn "Run: ./forward-openclaw.sh ${SANDBOX_NAME}"
      return 1
    }

    finalize_recovery "already-healthy"
    return 0
  fi

  if [[ "$health_state" != "prepair_pending" ]]; then
    case "$health_state" in
      listener_not_up)
        ui_warn "User-facing recovery path is not ready."
        ui_warn "OpenClaw listener is not up in the user-facing context."
        ;;
      health_unreachable)
        ui_warn "User-facing recovery path is not ready."
        ui_warn "Gateway health probe did not succeed."
        ;;
      *)
        ui_warn "User-facing recovery path is not ready."
        ui_warn "Run again with --debug for engineering diagnostics."
        ;;
    esac
    return 1
  fi

  ui_step "Evaluating CLI approval path"
  local cli_report_json
  cli_report_json="$(run_cli_map_report)"
  if [[ "$DEBUG" == "true" ]]; then
    printf '%s\n' "$cli_report_json"
  fi

  local cli_action
  local cli_safe_to_apply
  cli_action="$(json_get "$cli_report_json" "action")"
  cli_safe_to_apply="$(json_get "$cli_report_json" "safe_to_apply")"

  if [[ "$VERBOSE" == "true" || "$DEBUG" == "true" ]]; then
    ui_info "CLI approval action: ${cli_action:-<unknown>}"
  fi

  case "$cli_action" in
    approve_request_id)
      if [[ "$cli_safe_to_apply" != "true" ]]; then
        ui_warn "CLI approval path reported approve_request_id but not safe_to_apply."
        ui_warn "Run the lower-level repair helper manually only if you need it:"
        ui_warn "  ./lib/maintenance/repair-openclaw-operator-pairing.sh ${SANDBOX_NAME} --report-only --format text"
        return 1
      else
        if [[ "$DRY_RUN" == "true" ]]; then
          ui_info "Dry run: safe CLI approval detected but not applied."
        else
          ui_step "Applying CLI approval"
          local cli_apply_json
          cli_apply_json="$(run_cli_apply)"
          if [[ "$DEBUG" == "true" ]]; then
            printf '%s\n' "$cli_apply_json"
          fi

          local cli_changed
          cli_changed="$(json_get "$cli_apply_json" "changed")"
          if [[ "$cli_changed" != "true" ]]; then
            ui_warn "CLI approval helper did not report a state change."
            ui_warn "Run the lower-level repair helper manually only if you need it:"
            ui_warn "  ./lib/maintenance/repair-openclaw-operator-pairing.sh ${SANDBOX_NAME} --report-only --format text"
            return 1
          else
            ui_step "Verifying user-facing path"
            verify_json="$(run_verify)"
            if [[ "$DEBUG" == "true" ]]; then
              printf '%s\n' "$verify_json"
            fi

            user_path_ready="$(json_get "$verify_json" "user_path_ready")"
            health_state="$(json_get "$verify_json" "health_state")"

            if [[ "$user_path_ready" != "true" ]]; then
              case "$health_state" in
                prepair_pending)
                  ui_warn "User-facing recovery path is not ready."
                  ui_warn "Pairing repair is still required."
                  ;;
                listener_not_up)
                  ui_warn "User-facing recovery path is not ready."
                  ui_warn "OpenClaw listener is not up in the user-facing context."
                  ;;
                health_unreachable)
                  ui_warn "User-facing recovery path is not ready."
                  ui_warn "Gateway health probe did not succeed."
                  ;;
                *)
                  ui_warn "User-facing recovery path is not ready."
                  ui_warn "Run again with --debug for engineering diagnostics."
                  ;;
              esac
              return 1
            fi

            ui_step "Ensuring OpenClaw browser forward"
            run_forward_openclaw || {
              ui_warn "Sandbox recovery succeeded, but browser forward could not be confirmed."
              ui_warn "Run: ./forward-openclaw.sh ${SANDBOX_NAME}"
              return 1
            }

            finalize_recovery "cli"
            return 0
          fi
        fi
      fi
      ;;
    noop_already_paired)
      if [[ "$VERBOSE" == "true" || "$DEBUG" == "true" ]]; then
        ui_info "CLI path reports device is already paired."
      fi
      ui_step "Verifying user-facing path"
      verify_json="$(run_verify)"
      if [[ "$DEBUG" == "true" ]]; then
        printf '%s\n' "$verify_json"
      fi

      user_path_ready="$(json_get "$verify_json" "user_path_ready")"
      health_state="$(json_get "$verify_json" "health_state")"

      if [[ "$user_path_ready" != "true" ]]; then
        case "$health_state" in
          prepair_pending)
            ui_warn "User-facing recovery path is not ready."
            ui_warn "Pairing repair is still required."
            ;;
          listener_not_up)
            ui_warn "User-facing recovery path is not ready."
            ui_warn "OpenClaw listener is not up in the user-facing context."
            ;;
          health_unreachable)
            ui_warn "User-facing recovery path is not ready."
            ui_warn "Gateway health probe did not succeed."
            ;;
          *)
            ui_warn "User-facing recovery path is not ready."
            ui_warn "Run again with --debug for engineering diagnostics."
            ;;
        esac
        return 1
      fi

      ui_step "Ensuring OpenClaw browser forward"
      run_forward_openclaw || {
        ui_warn "Sandbox recovery succeeded, but browser forward could not be confirmed."
        ui_warn "Run: ./forward-openclaw.sh ${SANDBOX_NAME}"
        return 1
      }

      finalize_recovery "already-paired"
      return 0
      ;;
    refuse_cli_list_failed|refuse_no_cli_match|refuse_multiple_cli_matches|refuse_cli_missing_request_id)
      ui_warn "CLI approval path is not usable for this sandbox."
      ui_warn "Run the lower-level repair helper manually only if you need it:"
      ui_warn "  ./lib/maintenance/repair-openclaw-operator-pairing.sh ${SANDBOX_NAME} --report-only --format text"
      return 1
      ;;
    refuse_no_pending_match)
      ui_warn "CLI approval path found no pending local match."
      ui_warn "Run the lower-level repair helper manually only if you need it:"
      ui_warn "  ./lib/maintenance/repair-openclaw-operator-pairing.sh ${SANDBOX_NAME} --report-only --format text"
      return 1
      ;;
    refuse_multiple_pending_matches|refuse_multiple_paired_matches|error_missing_pending_json|error_missing_device_id|error_exception|"")
      ui_warn "CLI approval path was inconclusive."
      ui_warn "Run the lower-level repair helper manually only if you need it:"
      ui_warn "  ./lib/maintenance/repair-openclaw-operator-pairing.sh ${SANDBOX_NAME} --report-only --format text"
      return 1
      ;;
    *)
      ui_warn "Unknown CLI approval action '${cli_action}'."
      ui_warn "Run the lower-level repair helper manually only if you need it:"
      ui_warn "  ./lib/maintenance/repair-openclaw-operator-pairing.sh ${SANDBOX_NAME} --report-only --format text"
      return 1
      ;;
  esac
}

main "$@"
