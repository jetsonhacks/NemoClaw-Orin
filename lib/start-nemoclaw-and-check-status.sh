#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/script-ui.sh"

SANDBOX_NAME=""
FORMAT="text"
QUIET="${QUIET:-false}"
VERBOSE="${VERBOSE:-false}"
DEBUG="${DEBUG:-false}"

STATUS_TIMEOUT="${STATUS_TIMEOUT:-120}"
STATUS_INTERVAL="${STATUS_INTERVAL:-5}"
REQUIRE_KNOWN_INFERENCE="${REQUIRE_KNOWN_INFERENCE:-true}"
SKIP_START="${SKIP_START:-false}"

usage() {
  cat <<'EOF_USAGE'
Usage:
  ./start-nemoclaw-and-check-status.sh <sandbox-name> [flags]

Flags:
  --format json|text           Output format (default: text)
  --timeout <seconds>          Total wait timeout for status readiness (default: 120)
  --interval <seconds>         Poll interval (default: 5)
  --allow-unknown-inference    Treat reachable status as success even if provider/model remain unknown
  --skip-start                 Do not run `nemoclaw start`; only poll status
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
      --timeout)
        [[ $# -ge 2 ]] || die "Missing value for --timeout"
        STATUS_TIMEOUT="$2"
        shift 2
        ;;
      --interval)
        [[ $# -ge 2 ]] || die "Missing value for --interval"
        STATUS_INTERVAL="$2"
        shift 2
        ;;
      --allow-unknown-inference)
        REQUIRE_KNOWN_INFERENCE="false"
        shift
        ;;
      --skip-start)
        SKIP_START="true"
        shift
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
      -* )
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

capture_command() {
  local __outvar="$1"
  shift

  local output=""
  local rc=0
  set +e
  output="$($@ 2>&1)"
  rc=$?
  set -e

  printf -v "$__outvar" '%s' "$output"
  return "$rc"
}

run_nemoclaw_start() {
  nemoclaw start
}

run_sandbox_status() {
  nemoclaw "$SANDBOX_NAME" status
}

parse_status_json() {
  local raw_status="$1"
  RAW_STATUS="$raw_status" SANDBOX_NAME="$SANDBOX_NAME" python3 - <<'PY'
import json
import os
import re

text = os.environ["RAW_STATUS"]
sandbox_name = os.environ["SANDBOX_NAME"]

result = {
    "status_seen": False,
    "sandbox_name": sandbox_name,
    "sandbox_phase": "",
    "provider": "",
    "model": "",
    "nim_state": "",
    "inference_known": False,
}

if text.strip():
    result["status_seen"] = True

patterns = {
    "provider": r'^\s*Provider:\s*(.+?)\s*$',
    "model": r'^\s*Model:\s*(.+?)\s*$',
    "sandbox_phase": r'^\s*Phase:\s*(.+?)\s*$',
    "nim_state": r'^\s*NIM:\s*(.+?)\s*$',
}

for key, pattern in patterns.items():
    match = re.search(pattern, text, flags=re.MULTILINE)
    if match:
        result[key] = match.group(1).strip()

provider = result["provider"].lower()
model = result["model"].lower()
result["inference_known"] = bool(provider and model and provider != "unknown" and model != "unknown")

print(json.dumps(result))
PY
}

json_get() {
  local json_input="$1"
  local key="$2"
  JSON_INPUT="$json_input" JSON_KEY="$key" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
value = data.get(os.environ["JSON_KEY"], "")
if value is True:
    print("true")
elif value is False:
    print("false")
else:
    print(value)
PY
}

emit_json_result() {
  local ok="$1"
  local action="$2"
  local start_changed="$3"
  local provider="$4"
  local model="$5"
  local sandbox_phase="$6"
  local nim_state="$7"
  local waited_seconds="$8"
  local last_status_excerpt="$9"
  local start_output="${10:-}"

  OK="$ok" \
  ACTION="$action" \
  START_CHANGED="$start_changed" \
  PROVIDER="$provider" \
  MODEL="$model" \
  SANDBOX_PHASE="$sandbox_phase" \
  NIM_STATE="$nim_state" \
  WAITED_SECONDS="$waited_seconds" \
  LAST_STATUS_EXCERPT="$last_status_excerpt" \
  START_OUTPUT="$start_output" \
  python3 - <<'PY'
import json
import os

result = {
    "ok": os.environ["OK"] == "true",
    "action": os.environ["ACTION"],
    "start_attempted": os.environ["START_CHANGED"] == "true",
    "provider": os.environ["PROVIDER"] or "<unknown>",
    "model": os.environ["MODEL"] or "<unknown>",
    "sandbox_phase": os.environ["SANDBOX_PHASE"] or "<unknown>",
    "nim_state": os.environ["NIM_STATE"] or "<unknown>",
    "waited_seconds": int(os.environ["WAITED_SECONDS"]),
}
if os.environ["LAST_STATUS_EXCERPT"]:
    result["last_status_excerpt"] = os.environ["LAST_STATUS_EXCERPT"]
if os.environ["START_OUTPUT"]:
    result["start_output"] = os.environ["START_OUTPUT"]
print(json.dumps(result, indent=2))
PY
}

emit_text_result() {
  local ok="$1"
  local provider="$2"
  local model="$3"
  local sandbox_phase="$4"
  local nim_state="$5"
  local waited_seconds="$6"
  local action="$7"

  if [[ "$ok" == "true" ]]; then
    echo "NemoClaw managed services look ready"
  else
    echo "NemoClaw managed services do not look ready"
  fi
  echo "Action: ${action}"
  echo "Provider: ${provider:-<unknown>}"
  echo "Model: ${model:-<unknown>}"
  echo "Sandbox phase: ${sandbox_phase:-<unknown>}"
  echo "NIM state: ${nim_state:-<unknown>}"
  echo "Waited: ${waited_seconds}s"
}

main() {
  parse_args "$@"

  need_cmd nemoclaw
  need_cmd python3

  local start_output=""
  local start_attempted="false"

  if [[ "$SKIP_START" != "true" ]]; then
    if [[ "$FORMAT" == "text" ]]; then
      ui_step "Starting NemoClaw managed services"
    fi
    start_attempted="true"
    if ! capture_command start_output run_nemoclaw_start; then
      if [[ "$DEBUG" == "true" && -n "$start_output" ]]; then
        echo "--- nemoclaw start output ---" >&2
        printf '%s\n' "$start_output" >&2
      fi
    elif [[ "$DEBUG" == "true" && -n "$start_output" ]]; then
      echo "--- nemoclaw start output ---"
      printf '%s\n' "$start_output"
    fi
  fi

  local elapsed=0
  local last_status_output=""
  local last_status_json='{}'
  local last_status_excerpt=""
  local provider=""
  local model=""
  local sandbox_phase=""
  local nim_state=""
  local inference_known="false"
  local status_seen="false"

  if [[ "$FORMAT" == "text" ]]; then
    ui_step "Checking NemoClaw status"
  fi

  while [[ $elapsed -le $STATUS_TIMEOUT ]]; do
    if capture_command last_status_output run_sandbox_status; then
      last_status_json="$(parse_status_json "$last_status_output")"
      status_seen="$(json_get "$last_status_json" "status_seen")"
      provider="$(json_get "$last_status_json" "provider")"
      model="$(json_get "$last_status_json" "model")"
      sandbox_phase="$(json_get "$last_status_json" "sandbox_phase")"
      nim_state="$(json_get "$last_status_json" "nim_state")"
      inference_known="$(json_get "$last_status_json" "inference_known")"
      last_status_excerpt="$(printf '%s' "$last_status_output" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | cut -c1-240)"

      if [[ "$DEBUG" == "true" ]]; then
        echo "--- nemoclaw ${SANDBOX_NAME} status output ---"
        printf '%s\n' "$last_status_output"
      fi

      if [[ "$REQUIRE_KNOWN_INFERENCE" == "true" ]]; then
        if [[ "$inference_known" == "true" ]]; then
          case "$FORMAT" in
            json)
              emit_json_result "true" "ready_known_inference" "$start_attempted" "$provider" "$model" "$sandbox_phase" "$nim_state" "$elapsed" "$last_status_excerpt" "$start_output"
              ;;
            text)
              emit_text_result "true" "$provider" "$model" "$sandbox_phase" "$nim_state" "$elapsed" "ready_known_inference"
              ;;
          esac
          exit 0
        fi
      else
        if [[ "$status_seen" == "true" ]]; then
          case "$FORMAT" in
            json)
              emit_json_result "true" "ready_status_seen" "$start_attempted" "$provider" "$model" "$sandbox_phase" "$nim_state" "$elapsed" "$last_status_excerpt" "$start_output"
              ;;
            text)
              emit_text_result "true" "$provider" "$model" "$sandbox_phase" "$nim_state" "$elapsed" "ready_status_seen"
              ;;
          esac
          exit 0
        fi
      fi
    fi

    sleep "$STATUS_INTERVAL"
    elapsed=$((elapsed + STATUS_INTERVAL))
  done

  local final_action="timeout_waiting_for_known_inference"
  if [[ "$REQUIRE_KNOWN_INFERENCE" != "true" ]]; then
    final_action="timeout_waiting_for_status"
  fi

  case "$FORMAT" in
    json)
      emit_json_result "false" "$final_action" "$start_attempted" "$provider" "$model" "$sandbox_phase" "$nim_state" "$elapsed" "$last_status_excerpt" "$start_output"
      ;;
    text)
      emit_text_result "false" "$provider" "$model" "$sandbox_phase" "$nim_state" "$elapsed" "$final_action"
      ;;
  esac

  exit 1
}

main "$@"
