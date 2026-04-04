#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/lib/script-ui.sh"
source "$ROOT_DIR/lib/sandbox-kexec.sh"

SANDBOX_NAME=""
PHASE="unknown"
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
  lib/maintenance/inspect-openclaw-state.sh <sandbox-name> [flags]

Flags:
  --phase <name>   Label for the inspection phase (default: unknown)
  --format json    Emit machine-readable JSON only on stdout (default)
  --format text    Emit short human-readable output
  --quiet
  --verbose
  --debug
  --redact         Redact identifiers in output (default)
  --no-redact      Allow full identifiers in debug output
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --phase)
        [[ $# -ge 2 ]] || die "Missing value for --phase"
        PHASE="$2"
        shift 2
        ;;
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

run_python_core() {
  sandbox_kexec "$SANDBOX_NAME" sh -lc "
python3 - <<'PY'
import json
import sys
from pathlib import Path

phase = ${PHASE@Q}
debug_enabled = ${DEBUG@Q} == 'true'
redact_enabled = ${REDACT@Q} == 'true'

device_path = Path(${DEVICE_JSON@Q})
paired_path = Path(${PAIRED_JSON@Q})
pending_path = Path(${PENDING_JSON@Q})

def redact(value):
    if not redact_enabled:
        return value
    if not value:
        return '<unknown>'
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

def count_matches(obj, device_id):
    matches = 0
    if device_id is None:
        return 0
    if isinstance(obj, list):
        for entry in obj:
            if isinstance(entry, dict) and entry.get('deviceId') == device_id:
                matches += 1
    elif isinstance(obj, dict):
        for entry in obj.values():
            if isinstance(entry, dict) and entry.get('deviceId') == device_id:
                matches += 1
    return matches

result = {
    'ok': True,
    'phase': phase,
    'device_id_present': False,
    'device_id_redacted': '<unknown>',
    'paired_exists': False,
    'pending_exists': False,
    'paired_match_count': 0,
    'pending_match_count': 0,
}

try:
    device = None
    device_exists = device_path.exists()
    device_id = None

    if device_exists:
        try:
            device = json.loads(device_path.read_text())
            device_id = device.get('deviceId')
        except Exception:
            device = None
            device_id = None

    result['device_id_present'] = bool(device_id)
    result['device_id_redacted'] = redact(device_id)

    paired, paired_exists = load_json(paired_path, [])
    pending, pending_exists = load_json(pending_path, [])

    result['paired_exists'] = paired_exists
    result['pending_exists'] = pending_exists
    result['paired_match_count'] = count_matches(paired, device_id)
    result['pending_match_count'] = count_matches(pending, device_id)

    if debug_enabled and not redact_enabled:
        result['device_id'] = device_id
        result['device_json_exists'] = device_exists
        result['paired_type'] = type(paired).__name__ if paired_exists else None
        result['pending_type'] = type(pending).__name__ if pending_exists else None
        result['paired_count'] = len(paired) if isinstance(paired, (list, dict)) else None
        result['pending_count'] = len(pending) if isinstance(pending, (list, dict)) else None

    print(json.dumps(result, indent=2))
    sys.exit(0)

except Exception as e:
    failure = {
        'ok': False,
        'phase': phase,
        'action': 'error_exception',
    }
    if debug_enabled:
        failure['error'] = str(e)
    print(json.dumps(failure, indent=2))
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
phase = data.get("phase", "unknown")
device_present = "yes" if data.get("device_id_present") else "no"
paired_exists = "yes" if data.get("paired_exists") else "no"
pending_exists = "yes" if data.get("pending_exists") else "no"
paired_matches = data.get("paired_match_count", 0)
pending_matches = data.get("pending_match_count", 0)

print(f"OpenClaw state [{phase}]")
print(f"Device identity present: {device_present}")
print(f"Paired file present: {paired_exists}")
print(f"Pending file present: {pending_exists}")
print(f"Pending local operator match: {pending_matches}")
print(f"Paired local operator match: {paired_matches}")
PY
}

main() {
  parse_args "$@"
  need_cmd docker
  require_running_container

  local result_json
  result_json="$(run_python_core)"

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
