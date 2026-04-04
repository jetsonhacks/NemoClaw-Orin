#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/script-ui.sh"
source "$ROOT_DIR/lib/sandbox-kexec.sh"

SANDBOX_NAME=""
LABEL="${LABEL:-snapshot}"
OUTPUT_ROOT="${OUTPUT_ROOT:-$ROOT_DIR/tmp/test-openclaw-pairing-state}"
REDACT="${REDACT:-false}"

usage() {
  cat <<'EOF_USAGE'
Usage:
  ./tests/test-openclaw-pairing-state.sh <sandbox-name> [options]

Options:
  --label NAME         Short label for this capture (default: snapshot)
  --output-root PATH   Base output directory (default: ./tmp/test-openclaw-pairing-state)
  --redact             Redact identifiers in helper output
  --no-redact          Allow full identifiers in helper output (default)
  -h, --help           Show this help

Examples:
  ./tests/test-openclaw-pairing-state.sh da-claw --label post-approve
  ./tests/test-openclaw-pairing-state.sh da-claw --label idle-failure

This script captures:
  - verify-openclaw-user-path output
  - inspect-openclaw-state output
  - map-openclaw-cli-approval-target output
  - raw device.json / paired.json / pending.json from the sandbox
EOF_USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --label)
        [[ $# -ge 2 ]] || die "Missing value for --label"
        LABEL="$2"
        shift 2
        ;;
      --output-root)
        [[ $# -ge 2 ]] || die "Missing value for --output-root"
        OUTPUT_ROOT="$2"
        shift 2
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

sanitize_label() {
  printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '-'
}

capture_to_file() {
  local output_file="$1"
  shift

  local rc=0
  set +e
  "$@" >"$output_file" 2>&1
  rc=$?
  set -e

  return "$rc"
}

capture_json_helper() {
  local output_file="$1"
  shift

  local rc=0
  if capture_to_file "$output_file" "$@"; then
    return 0
  fi
  rc=$?

  {
    echo ""
    echo "__EXIT_CODE__=$rc"
  } >>"$output_file"
  return 0
}

capture_raw_state_file() {
  local sandbox_path="$1"
  local output_file="$2"

  local output=""
  local rc=0
  set +e
  output="$(sandbox_kexec "$SANDBOX_NAME" sh -lc "if [ -f ${sandbox_path@Q} ]; then cat ${sandbox_path@Q}; else echo '__MISSING__'; fi" 2>&1)"
  rc=$?
  set -e

  printf '%s\n' "$output" >"$output_file"
  return "$rc"
}

write_manifest() {
  local snapshot_dir="$1"

  SNAPSHOT_DIR="$snapshot_dir" python3 - <<'PY'
import hashlib
import os
from pathlib import Path

root = Path(os.environ["SNAPSHOT_DIR"])
for path in sorted(p for p in root.iterdir() if p.is_file()):
    data = path.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    print(f"{digest}  {path.name}")
PY
}

main() {
  parse_args "$@"

  need_cmd docker
  need_cmd openshell
  need_cmd python3

  local timestamp safe_label snapshot_dir
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  safe_label="$(sanitize_label "$LABEL")"
  snapshot_dir="${OUTPUT_ROOT}/${SANDBOX_NAME}/${timestamp}-${safe_label}"

  mkdir -p "$snapshot_dir"

  ui_step "Capturing pairing-state snapshot to $snapshot_dir"

  {
    printf 'sandbox=%s\n' "$SANDBOX_NAME"
    printf 'label=%s\n' "$LABEL"
    printf 'timestamp_utc=%s\n' "$timestamp"
    printf 'gateway_name=%s\n' "$GATEWAY_NAME"
    printf 'container_name=%s\n' "$CONTAINER_NAME"
    printf 'redact=%s\n' "$REDACT"
  } >"$snapshot_dir/metadata.txt"

  capture_json_helper \
    "$snapshot_dir/verify-openclaw-user-path.json" \
    "$ROOT_DIR/lib/verify-openclaw-user-path.sh" \
    "$SANDBOX_NAME" \
    --format json \
    --quiet

  if [[ "$REDACT" == "true" ]]; then
    capture_json_helper \
      "$snapshot_dir/inspect-openclaw-state.json" \
      "$ROOT_DIR/lib/maintenance/inspect-openclaw-state.sh" \
      "$SANDBOX_NAME" \
      --format json \
      --quiet \
      --redact

    capture_json_helper \
      "$snapshot_dir/map-openclaw-cli-approval-target.json" \
      "$ROOT_DIR/lib/map-openclaw-cli-approval-target.sh" \
      "$SANDBOX_NAME" \
      --format json \
      --quiet \
      --redact
  else
    capture_json_helper \
      "$snapshot_dir/inspect-openclaw-state.json" \
      "$ROOT_DIR/lib/maintenance/inspect-openclaw-state.sh" \
      "$SANDBOX_NAME" \
      --format json \
      --quiet \
      --debug \
      --no-redact

    capture_json_helper \
      "$snapshot_dir/map-openclaw-cli-approval-target.json" \
      "$ROOT_DIR/lib/map-openclaw-cli-approval-target.sh" \
      "$SANDBOX_NAME" \
      --format json \
      --quiet \
      --debug \
      --no-redact
  fi

  capture_raw_state_file "/sandbox/.openclaw-data/identity/device.json" "$snapshot_dir/device.json" || true
  capture_raw_state_file "/sandbox/.openclaw-data/devices/paired.json" "$snapshot_dir/paired.json" || true
  capture_raw_state_file "/sandbox/.openclaw-data/devices/pending.json" "$snapshot_dir/pending.json" || true

  write_manifest "$snapshot_dir" >"$snapshot_dir/SHA256SUMS.txt"

  ui_info "Snapshot complete."
  ui_info "Saved under: $snapshot_dir"
  ui_info "Compare snapshots with:"
  ui_info "  diff -ru <older-snapshot-dir> <newer-snapshot-dir>"
}

main "$@"
