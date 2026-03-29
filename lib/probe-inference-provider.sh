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
PROBE_TIMEOUT="${PROBE_TIMEOUT:-90}"
PROBE_MESSAGE="${PROBE_MESSAGE:-Reply with exactly OK.}"

usage() {
  cat <<'EOF_USAGE'
Usage:
  ./probe-inference-provider.sh <sandbox-name> [flags]

Flags:
  --format json|text     Output format (default: json)
  --timeout <seconds>    Probe timeout for openclaw agent (default: 90)
  --message <text>       Probe prompt (default: "Reply with exactly OK.")
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
        PROBE_TIMEOUT="$2"
        shift 2
        ;;
      --message)
        [[ $# -ge 2 ]] || die "Missing value for --message"
        PROBE_MESSAGE="$2"
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

try:
    data = json.loads(os.environ["JSON_INPUT"])
except Exception:
    print("")
    raise SystemExit(0)

value = data
for part in os.environ["JSON_EXPR"].split("."):
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

sanitize_single_line() {
  local text="${1:-}"
  printf '%s' "$text" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g'
}

make_excerpt() {
  local text="${1:-}"
  sanitize_single_line "$text" | cut -c1-240
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

collect_status_json() {
  if ! command -v nemoclaw >/dev/null 2>&1; then
    return 0
  fi
  nemoclaw "$SANDBOX_NAME" status --json 2>/dev/null || true
}

run_openclaw_probe() {
  local escaped_message
  escaped_message="$(printf '%q' "$PROBE_MESSAGE")"

  sandbox_ssh_command "$SANDBOX_NAME" "
    $(ssh_env_prefix)
    openclaw agent --agent main --local --message ${escaped_message} --timeout ${PROBE_TIMEOUT}
  "
}

extract_field_from_output() {
  local output="$1"
  local field_name="$2"

  OUTPUT="$output" FIELD_NAME="$field_name" python3 - <<'PY'
import os
import re

text = os.environ["OUTPUT"]
field = os.environ["FIELD_NAME"]

patterns = {
    "provider": [
        r'\bprovider=([^\s]+)',
        r'"provider"\s*:\s*"([^"]+)"',
    ],
    "model": [
        r'\bmodel=([^\s]+)',
        r'"model"\s*:\s*"([^"]+)"',
    ],
    "endpoint": [
        r'\bendpoint=([^\s]+)',
        r'"endpoint"\s*:\s*"([^"]+)"',
        r'\bbaseUrl=([^\s]+)',
    ],
}

for pattern in patterns.get(field, []):
    match = re.search(pattern, text)
    if match:
        print(match.group(1))
        raise SystemExit(0)

print("")
PY
}

probe_output_indicates_failure() {
  local output="$1"

  OUTPUT="$output" python3 - <<'PY'
import os
import re
import sys

text = os.environ["OUTPUT"]

failure_patterns = [
    r'\bisError=true\b',
    r'LLM request timed out',
    r'\brequest timed out\b',
    r'\btimeout\b',
    r'\berror=',
    r'\bforbidden\b',
    r'\bunauthorized\b',
    r'\bauthentication\b',
    r'\bconnection refused\b',
    r'\bECONNREFUSED\b',
    r'\bENOTFOUND\b',
    r'\bETIMEDOUT\b',
    r'\b429\b',
    r'\b500\b',
    r'\b502\b',
    r'\b503\b',
    r'\b504\b',
]

for pattern in failure_patterns:
    if re.search(pattern, text, re.IGNORECASE):
        sys.exit(0)

sys.exit(1)
PY
}

emit_json_result() {
  local ok="$1"
  local action="$2"
  local provider="$3"
  local model="$4"
  local endpoint="$5"
  local probe_timeout="$6"
  local response_excerpt="$7"
  local error_message="$8"

  OK="$ok" \
  ACTION="$action" \
  PROVIDER="$provider" \
  MODEL="$model" \
  ENDPOINT="$endpoint" \
  PROBE_TIMEOUT_VAL="$probe_timeout" \
  RESPONSE_EXCERPT="$response_excerpt" \
  ERROR_MESSAGE="$error_message" \
  python3 - <<'PY'
import json
import os

result = {
    "ok": os.environ["OK"] == "true",
    "action": os.environ["ACTION"],
    "provider": os.environ["PROVIDER"] or "<unknown>",
    "model": os.environ["MODEL"] or "<unknown>",
    "endpoint": os.environ["ENDPOINT"] or "<unknown>",
    "probe_timeout": int(os.environ["PROBE_TIMEOUT_VAL"]),
}
if os.environ["RESPONSE_EXCERPT"]:
    result["response_excerpt"] = os.environ["RESPONSE_EXCERPT"]
if os.environ["ERROR_MESSAGE"]:
    result["error"] = os.environ["ERROR_MESSAGE"]
print(json.dumps(result, indent=2))
PY
}

emit_text_result() {
  local ok="$1"
  local provider="$2"
  local model="$3"
  local endpoint="$4"
  local response_excerpt="$5"
  local error_message="$6"

  if [[ "$ok" == "true" ]]; then
    echo "Routed inference provider probe succeeded"
    echo "Provider: ${provider:-<unknown>}"
    echo "Model: ${model:-<unknown>}"
    echo "Endpoint: ${endpoint:-<unknown>}"
    if [[ -n "$response_excerpt" ]]; then
      echo "Response: ${response_excerpt}"
    fi
  else
    echo "Routed inference provider probe failed"
    echo "Provider: ${provider:-<unknown>}"
    echo "Model: ${model:-<unknown>}"
    echo "Endpoint: ${endpoint:-<unknown>}"
    if [[ -n "$error_message" ]]; then
      echo "Error: ${error_message}"
    fi
  fi
}

main() {
  parse_args "$@"

  need_cmd openshell
  need_cmd ssh
  need_cmd python3

  local status_json=""
  local provider=""
  local model=""
  local endpoint=""

  status_json="$(collect_status_json)"
  if [[ -n "$status_json" ]]; then
    provider="$(json_get "$status_json" "provider")"
    [[ -z "$provider" ]] && provider="$(json_get "$status_json" "inference.provider")"
    model="$(json_get "$status_json" "model")"
    [[ -z "$model" ]] && model="$(json_get "$status_json" "inference.model")"
    endpoint="$(json_get "$status_json" "endpoint")"
    [[ -z "$endpoint" ]] && endpoint="$(json_get "$status_json" "inference.endpoint")"
  fi

  local probe_output=""
  local probe_rc=0
  if capture_command probe_output run_openclaw_probe; then
    probe_rc=0
  else
    probe_rc=$?
  fi

  [[ -z "$provider" ]] && provider="$(extract_field_from_output "$probe_output" "provider")"
  [[ -z "$model" ]] && model="$(extract_field_from_output "$probe_output" "model")"
  [[ -z "$endpoint" ]] && endpoint="$(extract_field_from_output "$probe_output" "endpoint")"

  local excerpt=""
  excerpt="$(make_excerpt "$probe_output")"

  if [[ "$probe_rc" -eq 0 ]] && ! probe_output_indicates_failure "$probe_output"; then
    case "$FORMAT" in
      json)
        emit_json_result "true" "probe_openclaw_agent" "$provider" "$model" "$endpoint" "$PROBE_TIMEOUT" "$excerpt" ""
        ;;
      text)
        emit_text_result "true" "$provider" "$model" "$endpoint" "$excerpt" ""
        ;;
      *)
        die "Unsupported format: $FORMAT"
        ;;
    esac
    exit 0
  fi

  case "$FORMAT" in
    json)
      emit_json_result "false" "error_probe_openclaw_agent_failed" "$provider" "$model" "$endpoint" "$PROBE_TIMEOUT" "$excerpt" "$probe_output"
      ;;
    text)
      emit_text_result "false" "$provider" "$model" "$endpoint" "$excerpt" "$probe_output"
      ;;
    *)
      die "Unsupported format: $FORMAT"
      ;;
  esac

  exit 1
}

main "$@"