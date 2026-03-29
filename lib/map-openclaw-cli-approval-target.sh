#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/script-ui.sh"
source "$ROOT_DIR/lib/sandbox-kexec.sh"

SANDBOX_NAME=""
FORMAT="json"
QUIET="${QUIET:-false}"
VERBOSE="${VERBOSE:-false}"
DEBUG="${DEBUG:-false}"
REDACT="${REDACT:-true}"

DEVICE_JSON="/sandbox/.openclaw-data/identity/device.json"
PAIRED_JSON="/sandbox/.openclaw-data/devices/paired.json"
PENDING_JSON="/sandbox/.openclaw-data/devices/pending.json"

usage() {
  cat <<'EOF'
Usage:
  lib/map-openclaw-cli-approval-target.sh <sandbox-name> [flags]

Flags:
  --format json|text
  --quiet
  --verbose
  --debug
  --redact
  --no-redact
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
      --redact)
        REDACT="true"
        shift
        ;;
      --no-redact)
        REDACT="false"
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

collect_cli_devices_json() {
  sandbox_ssh_command "$SANDBOX_NAME" "
    $(ssh_env_prefix)
    openclaw devices list --json 2>&1
  "
}

run_python_core() {
  local cli_devices_json="$1"
  local cli_devices_b64
  cli_devices_b64="$(printf '%s' "$cli_devices_json" | base64 -w0)"

  sandbox_kexec "$SANDBOX_NAME" sh -lc "
python3 - <<'PY'
import base64
import json
import sys
from pathlib import Path

debug_enabled = ${DEBUG@Q} == 'true'
redact_enabled = ${REDACT@Q} == 'true'

device_path = Path(${DEVICE_JSON@Q})
paired_path = Path(${PAIRED_JSON@Q})
pending_path = Path(${PENDING_JSON@Q})
cli_raw_mixed = base64.b64decode(${cli_devices_b64@Q}).decode('utf-8')

def redact(value):
    if not redact_enabled:
        return value
    if not value:
        return '<unknown>'
    value = str(value)
    if len(value) <= 8:
        return '<redacted>'
    return '…' + value[-8:]

def load_json(path, default):
    if not path.exists():
        return default, False
    text = path.read_text().strip()
    if not text:
        return default, True
    return json.loads(text), True

def entries_with_device_id(obj, device_id):
    matches = []
    if isinstance(obj, list):
        for idx, entry in enumerate(obj):
            if isinstance(entry, dict) and entry.get('deviceId') == device_id:
                matches.append(('list', idx, entry))
    elif isinstance(obj, dict):
        for key, entry in obj.items():
            if isinstance(entry, dict) and entry.get('deviceId') == device_id:
                matches.append(('dict', key, entry))
    return matches

def normalize_array(value):
    return value if isinstance(value, list) else []

def extract_json_payload(text):
    lines = text.splitlines()
    for i, line in enumerate(lines):
        stripped = line.lstrip()
        if stripped.startswith('{') or stripped.startswith('['):
            candidate = '\n'.join(lines[i:])
            json.loads(candidate)
            return candidate
    raise ValueError('No JSON payload found in CLI output')

result = {
    'ok': False,
    'action': None,
    'safe_to_apply': False,
    'device_id_redacted': '<unknown>',
    'pending_match_count': 0,
    'paired_match_count': 0,
    'cli_pending_count': 0,
    'cli_paired_count': 0,
    'cli_candidate_count': 0,
    'fallback_mechanical_possible': False,
}

try:
    device = json.loads(device_path.read_text())
    device_id = device.get('deviceId')
    if not device_id:
        result['action'] = 'error_missing_device_id'
        print(json.dumps(result, indent=2))
        sys.exit(0)

    result['device_id_redacted'] = redact(device_id)

    paired_local, paired_exists = load_json(paired_path, None)
    pending_local, pending_exists = load_json(pending_path, None)

    if not pending_exists:
        result['action'] = 'error_missing_pending_json'
        print(json.dumps(result, indent=2))
        sys.exit(0)

    if pending_local is None:
        pending_local = []

    paired_matches = entries_with_device_id(paired_local if paired_local is not None else [], device_id)
    pending_matches = entries_with_device_id(pending_local, device_id)

    result['paired_match_count'] = len(paired_matches)
    result['pending_match_count'] = len(pending_matches)
    result['fallback_mechanical_possible'] = (
        len(paired_matches) == 0 and len(pending_matches) == 1
    )

    cli_obj = None
    cli_json_payload = None
    try:
        cli_json_payload = extract_json_payload(cli_raw_mixed)
        cli_obj = json.loads(cli_json_payload)
        cli_pending = normalize_array(cli_obj.get('pending'))
        cli_paired = normalize_array(cli_obj.get('paired'))
        result['cli_pending_count'] = len(cli_pending)
        result['cli_paired_count'] = len(cli_paired)
    except Exception as e:
        cli_pending = []
        cli_paired = []
        if debug_enabled:
            result['cli_parse_error'] = str(e)

    if len(paired_matches) == 1 and len(pending_matches) == 0:
        result['ok'] = True
        result['action'] = 'noop_already_paired'
        if debug_enabled and not redact_enabled:
            result['device_id'] = device_id
            result['cli_pending_entries'] = cli_pending
            result['cli_paired_entries'] = cli_paired
        print(json.dumps(result, indent=2))
        sys.exit(0)

    if len(paired_matches) > 1:
        result['action'] = 'refuse_multiple_paired_matches'
        print(json.dumps(result, indent=2))
        sys.exit(0)

    if len(pending_matches) == 0:
        result['action'] = 'refuse_no_pending_match'
        print(json.dumps(result, indent=2))
        sys.exit(0)

    if len(pending_matches) > 1:
        result['action'] = 'refuse_multiple_pending_matches'
        print(json.dumps(result, indent=2))
        sys.exit(0)

    _, _, local_pending_entry = pending_matches[0]

    if cli_obj is None:
        result['ok'] = True
        result['action'] = 'refuse_cli_list_failed'
        if debug_enabled:
            result['cli_raw'] = cli_raw_mixed
        print(json.dumps(result, indent=2))
        sys.exit(0)

    candidates = []
    for idx, entry in enumerate(cli_pending):
        if not isinstance(entry, dict):
            continue
        if entry.get('deviceId') == device_id:
            candidates.append((idx, entry))

    result['cli_candidate_count'] = len(candidates)

    if len(candidates) == 0:
        result['ok'] = True
        result['action'] = 'refuse_no_cli_match'
        if debug_enabled:
            result['candidate_keys'] = sorted(local_pending_entry.keys()) if isinstance(local_pending_entry, dict) else []
            if not redact_enabled:
                result['cli_pending_entries'] = cli_pending
        print(json.dumps(result, indent=2))
        sys.exit(0)

    if len(candidates) > 1:
        result['ok'] = True
        result['action'] = 'refuse_multiple_cli_matches'
        if debug_enabled:
            result['candidate_indexes'] = [idx for idx, _ in candidates]
        print(json.dumps(result, indent=2))
        sys.exit(0)

    _, chosen = candidates[0]
    request_id = chosen.get('requestId')

    if not request_id:
        result['ok'] = True
        result['action'] = 'refuse_cli_missing_request_id'
        if debug_enabled:
            result['chosen_keys'] = sorted(chosen.keys())
        print(json.dumps(result, indent=2))
        sys.exit(0)

    result['ok'] = True
    result['action'] = 'approve_request_id'
    result['safe_to_apply'] = True
    result['request_id_redacted'] = redact(request_id)
    result['match_basis'] = 'exact_device_id'
    result['fallback_mechanical_possible'] = True

    if debug_enabled and not redact_enabled:
        result['device_id'] = device_id
        result['request_id'] = request_id
        result['matched_pending_entry'] = local_pending_entry
        result['chosen_cli_entry'] = chosen
        result['cli_pending_entries'] = cli_pending
        result['cli_paired_entries'] = cli_paired

    print(json.dumps(result, indent=2))
    sys.exit(0)

except Exception as e:
    result['ok'] = False
    result['action'] = 'error_exception'
    if debug_enabled:
        result['error'] = str(e)
    print(json.dumps(result, indent=2))
    sys.exit(10)
PY
"
}

emit_text() {
  local json_input="$1"
  JSON_INPUT="$json_input" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
action = data.get("action")
device = data.get("device_id_redacted", "<unknown>")
request = data.get("request_id_redacted", "<unknown>")
basis = data.get("match_basis")

if action == "approve_request_id":
    print("CLI approval target: safe approval available")
    print(f"Candidate device: {device}")
    print(f"Request id: {request}")
    print(f"Match basis: {basis}")
elif action == "noop_already_paired":
    print("CLI approval target: already paired")
    print(f"Candidate device: {device}")
elif action == "refuse_no_cli_match":
    print("CLI approval target: no deterministic CLI match")
    print(f"Candidate device: {device}")
elif action == "refuse_multiple_cli_matches":
    print("CLI approval target: multiple CLI matches")
    print(f"Candidate device: {device}")
elif action == "refuse_cli_missing_request_id":
    print("CLI approval target: matched CLI entry lacks request id")
    print(f"Candidate device: {device}")
elif action == "refuse_cli_list_failed":
    print("CLI approval target: could not obtain CLI device list")
    print(f"Candidate device: {device}")
else:
    print("CLI approval target: no safe automatic CLI approval")
    print(f"Action: {action}")
    print(f"Candidate device: {device}")
PY
}

main() {
  parse_args "$@"

  need_cmd docker
  need_cmd openshell
  need_cmd ssh
  need_cmd python3
  need_cmd base64
  require_running_container

  local cli_devices_json
  cli_devices_json="$(collect_cli_devices_json)"

  local result_json
  result_json="$(run_python_core "$cli_devices_json")"

  case "$FORMAT" in
    json)
      printf '%s\n' "$result_json"
      ;;
    text)
      emit_text "$result_json"
      ;;
    *)
      die "Unsupported format: $FORMAT"
      ;;
  esac
}

main "$@"