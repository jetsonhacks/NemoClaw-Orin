#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/lib/script-ui.sh"

SANDBOX_NAME=""
QUIET="${QUIET:-false}"
VERBOSE="${VERBOSE:-false}"
DEBUG="${DEBUG:-false}"
DRY_RUN="${DRY_RUN:-false}"
SKIP_OUTER_RESTART="${SKIP_OUTER_RESTART:-false}"

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

run_inspect() {
  local phase="$1"
  "$ROOT_DIR/lib/inspect-openclaw-state.sh" \
    "$SANDBOX_NAME" \
    --phase "$phase" \
    --format json \
    --quiet
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

run_handshake_report() {
  "$ROOT_DIR/lib/reconcile-sandbox-ssh-handshake.sh" \
    "$SANDBOX_NAME" \
    --report-only \
    --format json \
    --quiet
}

run_handshake_apply() {
  "$ROOT_DIR/lib/reconcile-sandbox-ssh-handshake.sh" \
    "$SANDBOX_NAME" \
    --apply \
    --format json \
    --quiet
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

run_repair_report() {
  "$ROOT_DIR/lib/repair-openclaw-operator-pairing.sh" \
    "$SANDBOX_NAME" \
    --report-only \
    --format json \
    --quiet
}

run_repair_apply() {
  "$ROOT_DIR/lib/repair-openclaw-operator-pairing.sh" \
    "$SANDBOX_NAME" \
    --apply \
    --format json \
    --quiet
}

run_verify() {
  "$ROOT_DIR/lib/verify-openclaw-user-path.sh" \
    "$SANDBOX_NAME" \
    --format json \
    --quiet
}

debug_report_success_path() {
  local path_name="$1"
  if [[ "$DEBUG" == "true" ]]; then
    ui_info "Successful recovery path: ${path_name}"
  fi
}

show_next_steps() {
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

  ui_step "Reconciling sandbox SSH handshake state"
  local handshake_report_json
  handshake_report_json="$(run_handshake_report)"
  if [[ "$DEBUG" == "true" ]]; then
    printf "%s\n" "$handshake_report_json"
  fi

  local handshake_action
  local handshake_safe_to_apply
  handshake_action="$(json_get "$handshake_report_json" "action")"
  handshake_safe_to_apply="$(json_get "$handshake_report_json" "safe_to_apply")"

  case "$handshake_action" in
    noop_already_reconciled)
      if [[ "$VERBOSE" == "true" || "$DEBUG" == "true" ]]; then
        ui_info "Sandbox SSH handshake secret already matches the gateway."
      fi
      ;;
    reconcile_sandbox_handshake_secret)
      if [[ "$DRY_RUN" == "true" ]]; then
        ui_info "Dry run: sandbox SSH handshake drift detected but not reconciled."
      elif [[ "$handshake_safe_to_apply" == "true" ]]; then
        ui_step "Applying sandbox SSH handshake reconciliation"
        local handshake_apply_json
        handshake_apply_json="$(run_handshake_apply)"
        if [[ "$DEBUG" == "true" ]]; then
          printf "%s\n" "$handshake_apply_json"
        fi
        local handshake_changed
        handshake_changed="$(json_get "$handshake_apply_json" "changed")"
        if [[ "$handshake_changed" != "true" ]]; then
          ui_warn "Sandbox SSH handshake helper did not report a state change."
          return 1
        fi
      else
        ui_warn "Sandbox SSH handshake drift detected, but helper marked it unsafe to apply."
        return 1
      fi
      ;;
    error_missing_gateway_secret|error_missing_sandbox_secret|error_exception|"")
      ui_warn "Could not inspect sandbox SSH handshake state automatically."
      ui_warn "Run again with --debug for engineering diagnostics."
      return 1
      ;;
    *)
      if [[ "$VERBOSE" == "true" || "$DEBUG" == "true" ]]; then
        ui_info "Sandbox SSH handshake state action: ${handshake_action}"
      fi
      ;;
  esac

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

  ui_step "Inspecting pre-start state"
  local pre_json
  pre_json="$(run_inspect pre-start)"
  if [[ "$DEBUG" == "true" ]]; then
    printf '%s\n' "$pre_json"
    local pre_pending pre_paired
    pre_pending="$(json_get "$pre_json" "pending_match_count" 2>/dev/null || true)"
    pre_paired="$(json_get "$pre_json" "paired_match_count" 2>/dev/null || true)"
    ui_info "Pre-start summary: pending=${pre_pending:-?} paired=${pre_paired:-?}"
  fi

  ui_step "Inspecting post-start state"
  local post_json
  post_json="$(run_inspect post-start)"
  if [[ "$DEBUG" == "true" ]]; then
    printf '%s\n' "$post_json"
    local post_pending post_paired
    post_pending="$(json_get "$post_json" "pending_match_count" 2>/dev/null || true)"
    post_paired="$(json_get "$post_json" "paired_match_count" 2>/dev/null || true)"
    ui_info "Post-start summary: pending=${post_pending:-?} paired=${post_paired:-?}"
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
        ui_warn "Falling back to mechanical repair path."
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
            ui_warn "Falling back to mechanical repair path."
          else
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

            debug_report_success_path "cli"
            show_next_steps
            return 0
          fi
        fi
      fi
      ;;
    noop_already_paired)
      if [[ "$VERBOSE" == "true" || "$DEBUG" == "true" ]]; then
        ui_info "CLI path reports device is already paired."
      fi
      ;;
    refuse_cli_list_failed|refuse_no_cli_match|refuse_multiple_cli_matches|refuse_cli_missing_request_id)
      if [[ "$VERBOSE" == "true" || "$DEBUG" == "true" ]]; then
        ui_info "CLI path not usable; falling back to mechanical repair."
      fi
      ;;
    refuse_no_pending_match)
      if [[ "$VERBOSE" == "true" || "$DEBUG" == "true" ]]; then
        ui_info "CLI path found no pending local match."
      fi
      ;;
    refuse_multiple_pending_matches|refuse_multiple_paired_matches|error_missing_pending_json|error_missing_device_id|error_exception|"")
      if [[ "$VERBOSE" == "true" || "$DEBUG" == "true" ]]; then
        ui_info "CLI path inconclusive; falling back to mechanical repair."
      fi
      ;;
    *)
      if [[ "$VERBOSE" == "true" || "$DEBUG" == "true" ]]; then
        ui_info "Unknown CLI action '${cli_action}'; falling back to mechanical repair."
      fi
      ;;
  esac

  ui_step "Evaluating mechanical recovery state"
  local repair_report_json
  repair_report_json="$(run_repair_report)"
  if [[ "$DEBUG" == "true" ]]; then
    printf '%s\n' "$repair_report_json"
  fi

  local repair_action
  local safe_to_apply
  repair_action="$(json_get "$repair_report_json" "action")"
  safe_to_apply="$(json_get "$repair_report_json" "safe_to_apply")"

  if [[ "$VERBOSE" == "true" || "$DEBUG" == "true" ]]; then
    ui_info "Mechanical repair action: ${repair_action:-<unknown>}"
  fi

  if [[ "$safe_to_apply" == "true" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      ui_info "Dry run: safe mechanical recovery action detected but not applied."
    else
      ui_step "Applying safe mechanical recovery action"
      local apply_json
      apply_json="$(run_repair_apply)"
      if [[ "$DEBUG" == "true" ]]; then
        printf '%s\n' "$apply_json"
      fi

      local changed
      changed="$(json_get "$apply_json" "changed")"
      if [[ "$changed" != "true" ]]; then
        ui_warn "Mechanical repair helper did not report a state change."
        return 1
      fi
    fi
  else
    case "$repair_action" in
      noop_already_paired)
        if [[ "$VERBOSE" == "true" || "$DEBUG" == "true" ]]; then
          ui_info "Operator state is already paired."
        fi
        ;;
      error_missing_pending_json)
        ui_warn "Pending operator file is not yet present after gateway start."
        ui_warn "Recovery paused before automatic repair."
        return 1
        ;;
      refuse_no_pending_match)
        ui_warn "No matching pending operator request was found."
        ui_warn "Recovery paused before automatic repair."
        return 1
        ;;
      refuse_multiple_pending_matches)
        ui_warn "Multiple matching pending operator requests were found."
        ui_warn "Recovery paused before automatic repair."
        return 1
        ;;
      refuse_multiple_paired_matches)
        ui_warn "Multiple matching paired operator entries were found."
        ui_warn "Recovery paused before automatic repair."
        return 1
        ;;
      *)
        ui_warn "Recovery paused: ${repair_action:-unknown repair state}."
        ui_warn "Run again with --debug for engineering diagnostics."
        return 1
        ;;
    esac
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

  debug_report_success_path "mechanical"
  show_next_steps
}

main "$@"