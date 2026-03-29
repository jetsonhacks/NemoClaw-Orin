#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/script-ui.sh"
source "$ROOT_DIR/lib/sandbox-kexec.sh"

SANDBOX_NAME=""
MODE="--report-only"
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
  lib/repair-openclaw-operator-pairing.sh <sandbox-name> [mode] [flags]

Modes:
  --report-only    Analyze only (default)
  --apply          Apply the safe pending -> paired promotion if eligible

Flags:
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
      --report-only|--apply)
        MODE="$1"
        shift
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
import shutil
import sys
from pathlib import Path
from datetime import datetime

mode = ${MODE@Q}
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
    text = path.read_text()
    if not text.strip():
        return default, True
    return json.loads(text), True

def backup(path):
    ts = datetime.utcnow().strftime('%Y%m%dT%H%M%SZ')
    backup_path = path.with_name(path.name + '.bak.' + ts)
    if path.exists():
        shutil.copy2(path, backup_path)
    return str(backup_path)

def atomic_write_json(path, obj):
    tmp = path.with_name(path.name + '.tmp')
    tmp.write_text(json.dumps(obj, indent=2) + '\\n')
    tmp.replace(path)

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

result = {
    'ok': False,
    'action': None,
    'safe_to_apply': False,
    'changed': False,
    'paired_match_count': None,
    'pending_match_count': None,
    'candidate_count': 0,
    'device_id_redacted': '<unknown>',
}

def finish(exit_code=0):
    print(json.dumps(result, indent=2))
    sys.exit(exit_code)

try:
    device = json.loads(device_path.read_text())
    device_id = device.get('deviceId')
    if not device_id:
        result['action'] = 'error_missing_device_id'
        finish(0)

    result['device_id_redacted'] = redact(device_id)

    paired, paired_exists = load_json(paired_path, None)
    pending, pending_exists = load_json(pending_path, None)

    if not pending_exists:
        result['action'] = 'error_missing_pending_json'
        finish(0)

    if pending is None:
        pending = []

    paired_matches = entries_with_device_id(paired if paired is not None else [], device_id)
    pending_matches = entries_with_device_id(pending, device_id)

    result['paired_match_count'] = len(paired_matches)
    result['pending_match_count'] = len(pending_matches)
    result['candidate_count'] = len(pending_matches)

    if debug_enabled and not redact_enabled:
        result['device_id'] = device_id
        result['paired_exists'] = paired_exists
        result['pending_exists'] = pending_exists
        result['paired_type'] = type(paired).__name__ if paired is not None else None
        result['pending_type'] = type(pending).__name__

    if len(paired_matches) == 1:
        result['ok'] = True
        result['action'] = 'noop_already_paired'
        result['safe_to_apply'] = False
        finish(0)

    if len(paired_matches) > 1:
        result['action'] = 'refuse_multiple_paired_matches'
        finish(0)

    if len(pending_matches) == 0:
        result['action'] = 'refuse_no_pending_match'
        finish(0)

    if len(pending_matches) > 1:
        result['action'] = 'refuse_multiple_pending_matches'
        finish(0)

    _, pending_locator, entry = pending_matches[0]
    result['action'] = 'promote_pending_to_paired'
    result['safe_to_apply'] = True
    result['ok'] = True

    if debug_enabled:
        result['candidate_keys'] = sorted(entry.keys())

    if mode != '--apply':
        finish(0)

    if paired is None:
        if isinstance(pending, list):
            paired = []
        elif isinstance(pending, dict):
            paired = {}
        else:
            result['ok'] = False
            result['action'] = 'error_cannot_infer_paired_shape'
            finish(0)

    if not isinstance(paired, (list, dict)):
        result['ok'] = False
        result['action'] = 'error_unsupported_paired_type'
        finish(0)

    if not isinstance(pending, (list, dict)):
        result['ok'] = False
        result['action'] = 'error_unsupported_pending_type'
        finish(0)

    paired_backup = backup(paired_path)
    pending_backup = backup(pending_path)

    if isinstance(paired, list):
        paired.append(entry)
    else:
        key = entry.get('deviceId') or f'paired-{device_id}'
        paired[key] = entry

    if isinstance(pending, list):
        del pending[pending_locator]
    else:
        del pending[pending_locator]

    atomic_write_json(paired_path, paired)
    atomic_write_json(pending_path, pending)

    result['ok'] = True
    result['changed'] = True
    result['action'] = 'applied_promote_pending_to_paired'

    if debug_enabled:
        result['paired_backup'] = paired_backup
        result['pending_backup'] = pending_backup

    finish(0)

except SystemExit:
    raise
except Exception as e:
    result['ok'] = False
    result['action'] = 'error_exception'
    if debug_enabled:
        result['error'] = str(e)
    finish(10)
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
pending = data.get("pending_match_count")
paired = data.get("paired_match_count")

if action == "promote_pending_to_paired":
    print("Operator recovery state: safe repair available")
    print(f"Pending matches: {pending}")
    print(f"Paired matches: {paired}")
    print(f"Candidate device: {device}")
elif action == "applied_promote_pending_to_paired":
    print("Applied operator recovery repair")
    print(f"Candidate device: {device}")
elif action == "noop_already_paired":
    print("Operator recovery state: already paired")
    print(f"Candidate device: {device}")
elif action == "error_missing_pending_json":
    print("Operator recovery state: pending operator file not yet present")
    print(f"Candidate device: {device}")
elif action == "refuse_no_pending_match":
    print("Operator recovery state: no matching pending operator request")
    print(f"Candidate device: {device}")
elif action == "refuse_multiple_pending_matches":
    print("Operator recovery state: multiple matching pending operator requests")
    print(f"Candidate device: {device}")
elif action == "refuse_multiple_paired_matches":
    print("Operator recovery state: multiple matching paired operator entries")
    print(f"Candidate device: {device}")
else:
    print("Operator recovery state: no safe automatic repair")
    print(f"Action: {action}")
    if pending is not None:
        print(f"Pending matches: {pending}")
    if paired is not None:
        print(f"Paired matches: {paired}")
    print(f"Candidate device: {device}")
PY
}

normalize_ownership() {
  sandbox_kexec "$SANDBOX_NAME" sh -lc "
for p in '${PAIRED_JSON}' '${PENDING_JSON}'; do
  if [ -e \"\$p\" ]; then
    chown sandbox:sandbox \"\$p\" || true
  fi
done
"
}

main() {
  parse_args "$@"
  need_cmd docker
  require_running_container

  local result_json
  result_json="$(run_python_core)"

  if [[ "$MODE" == "--apply" ]]; then
    local changed
    changed="$(printf '%s' "$result_json" | python3 -c 'import sys, json; print("true" if json.load(sys.stdin).get("changed") else "false")')"
    if [[ "$changed" == "true" ]]; then
      if is_verbose || is_debug; then
        ui_info "Normalizing repaired file ownership"
      fi
      normalize_ownership
    fi
  fi

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