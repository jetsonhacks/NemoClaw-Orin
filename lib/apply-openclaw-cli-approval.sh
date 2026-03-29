#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/script-ui.sh"

SANDBOX_NAME=""
FORMAT="json"
QUIET="${QUIET:-false}"
VERBOSE="${VERBOSE:-false}"
DEBUG="${DEBUG:-false}"

usage() {
  cat <<'EOF'
Usage:
  lib/apply-openclaw-cli-approval.sh <sandbox-name> [flags]

Flags:
  --format json|text
  --quiet
  --verbose
  --debug
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

redact_value_python() {
  local value="${1:-}"
  VALUE="$value" python3 - <<'PY'
import os
value = os.environ.get("VALUE", "")
if not value:
    print("<unknown>")
elif len(value) <= 8:
    print("<redacted>")
else:
    print("…" + value[-8:])
PY
}

sanitize_mapper_report_json() {
  local mapper_json="$1"
  JSON_INPUT="$mapper_json" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_INPUT"])

allowed = {
    "ok",
    "action",
    "safe_to_apply",
    "device_id_redacted",
    "pending_match_count",
    "paired_match_count",
    "cli_pending_count",
    "cli_paired_count",
    "cli_candidate_count",
    "fallback_mechanical_possible",
    "request_id_redacted",
    "match_basis",
}

sanitized = {k: v for k, v in data.items() if k in allowed}
print(json.dumps(sanitized, indent=2))
PY
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
    -o "ProxyCommand=${openshell_bin} ssh-proxy --gateway-name ${GATEWAY_NAME:-nemoclaw} --name ${sandbox_name}" \
    "sandbox@openshell-${sandbox_name}" \
    "${cmd}"
}

ssh_env_prefix() {
  cat <<'EOF'
unset NODE_USE_ENV_PROXY HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy grpc_proxy;
export NO_PROXY=127.0.0.1,localhost,::1;
export no_proxy=127.0.0.1,localhost,::1;
export HOME=/sandbox;
EOF
}

run_mapper_for_internal_use() {
  local args=(
    "$SANDBOX_NAME"
    --format json
    --quiet
    --debug
    --no-redact
  )

  "$ROOT_DIR/lib/map-openclaw-cli-approval-target.sh" "${args[@]}"
}

run_cli_approve() {
  local request_id="$1"

  sandbox_ssh_command "$SANDBOX_NAME" "
    $(ssh_env_prefix)
    openclaw devices approve ${request_id@Q} --json 2>&1
  "
}

extract_json_payload_python() {
  local mixed_text="$1"
  MIXED_TEXT="$mixed_text" python3 - <<'PY'
import json
import os
import sys

text = os.environ["MIXED_TEXT"]
lines = text.splitlines()
for i, line in enumerate(lines):
    stripped = line.lstrip()
    if stripped.startswith("{") or stripped.startswith("["):
        candidate = "\n".join(lines[i:])
        json.loads(candidate)
        print(candidate)
        sys.exit(0)

sys.exit(1)
PY
}

emit_json_result() {
  local ok="$1"
  local action="$2"
  local changed="$3"
  local request_id_redacted="$4"
  local raw_cli_json="${5:-}"
  local error_message="${6:-}"

  OK="$ok" \
  ACTION="$action" \
  CHANGED="$changed" \
  REQUEST_ID_REDACTED="$request_id_redacted" \
  RAW_CLI_JSON="$raw_cli_json" \
  ERROR_MESSAGE="$error_message" \
  python3 - <<'PY'
import json
import os

result = {
    "ok": os.environ["OK"] == "true",
    "action": os.environ["ACTION"],
    "changed": os.environ["CHANGED"] == "true",
    "request_id_redacted": os.environ["REQUEST_ID_REDACTED"] or "<unknown>",
}

raw_cli_json = os.environ["RAW_CLI_JSON"]
if raw_cli_json:
    try:
        result["cli_result"] = json.loads(raw_cli_json)
    except Exception:
        result["cli_raw"] = raw_cli_json

if os.environ["ERROR_MESSAGE"]:
    result["error"] = os.environ["ERROR_MESSAGE"]

print(json.dumps(result, indent=2))
PY
}

emit_text_result() {
  local action="$1"
  local request_id_redacted="$2"
  local error_message="${3:-}"

  case "$action" in
    applied_cli_approve_request_id)
      echo "Applied CLI approval for pending device request"
      echo "Request id: ${request_id_redacted}"
      ;;
    approve_request_id)
      echo "CLI approval is available but was not applied"
      echo "Request id: ${request_id_redacted}"
      ;;
    noop_already_paired)
      echo "CLI approval not needed"
      echo "Device is already paired"
      ;;
    *)
      echo "CLI approval was not applied"
      echo "Action: ${action}"
      [[ -n "$error_message" ]] && echo "Error: ${error_message}"
      ;;
  esac
}

main() {
  parse_args "$@"

  need_cmd openshell
  need_cmd ssh
  need_cmd python3

  local report_json
  report_json="$(run_mapper_for_internal_use)"

  local action
  local safe_to_apply
  local request_id
  local request_id_redacted

  action="$(json_get "$report_json" "action")"
  safe_to_apply="$(json_get "$report_json" "safe_to_apply")"
  request_id="$(json_get "$report_json" "request_id")"
  request_id_redacted="$(json_get "$report_json" "request_id_redacted")"

  if [[ "$action" != "approve_request_id" || "$safe_to_apply" != "true" || -z "$request_id" ]]; then
    local sanitized_report_json
    sanitized_report_json="$(sanitize_mapper_report_json "$report_json")"

    case "$FORMAT" in
      json)
        printf '%s\n' "$sanitized_report_json"
        ;;
      text)
        emit_text_result "$action" "$request_id_redacted"
        ;;
      *)
        die "Unsupported format: $FORMAT"
        ;;
    esac
    exit 0
  fi

  local approve_output=""
  local approve_rc=0
  approve_output="$(run_cli_approve "$request_id")" || approve_rc=$?

  local parsed_cli_json=""
  if [[ $approve_rc -eq 0 ]]; then
    parsed_cli_json="$(extract_json_payload_python "$approve_output" 2>/dev/null || true)"
  fi

  if [[ $approve_rc -ne 0 ]]; then
    case "$FORMAT" in
      json)
        emit_json_result "false" "error_cli_approve_failed" "false" "$request_id_redacted" "" "$approve_output"
        ;;
      text)
        emit_text_result "error_cli_approve_failed" "$request_id_redacted" "$approve_output"
        ;;
      *)
        die "Unsupported format: $FORMAT"
        ;;
    esac
    exit 1
  fi

  if [[ -z "$parsed_cli_json" ]]; then
    case "$FORMAT" in
      json)
        emit_json_result "false" "error_cli_approve_parse_failed" "false" "$request_id_redacted" "" "$approve_output"
        ;;
      text)
        emit_text_result "error_cli_approve_parse_failed" "$request_id_redacted" "$approve_output"
        ;;
      *)
        die "Unsupported format: $FORMAT"
        ;;
    esac
    exit 1
  fi

  local final_request_id_redacted="$request_id_redacted"
  local cli_request_id
  cli_request_id="$(json_get "$parsed_cli_json" "requestId")"
  if [[ -n "$cli_request_id" ]]; then
    final_request_id_redacted="$(redact_value_python "$cli_request_id")"
  fi

  case "$FORMAT" in
    json)
      emit_json_result "true" "applied_cli_approve_request_id" "true" "$final_request_id_redacted" "$parsed_cli_json"
      ;;
    text)
      emit_text_result "applied_cli_approve_request_id" "$final_request_id_redacted"
      ;;
    *)
      die "Unsupported format: $FORMAT"
      ;;
  esac
}

main "$@"