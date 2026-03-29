#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$ROOT_DIR/lib/script-ui.sh"

SANDBOX_NAME=""
MODE="--report-only"
FORMAT="json"
QUIET="${QUIET:-false}"
VERBOSE="${VERBOSE:-false}"
DEBUG="${DEBUG:-false}"
REDACT="${REDACT:-true}"
POD_READY_TIMEOUT="${POD_READY_TIMEOUT:-120}"

usage() {
  cat <<'EOF_USAGE'
Usage:
  ./reconcile-sandbox-ssh-handshake.sh <sandbox-name> [mode] [flags]

Modes:
  --report-only    Analyze only (default)
  --apply          Reconcile sandbox handshake secret if it drifted

Flags:
  --format json|text
  --quiet
  --verbose
  --debug
  --redact
  --no-redact
EOF_USAGE
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

kctl() {
  docker exec "$CONTAINER_NAME" kubectl "$@" 2>/dev/null
}

wait_for_pod_uid_change() {
  local pod_name="$1"
  local old_uid="$2"
  local elapsed=0
  local interval=2

  [[ -n "$old_uid" ]] || return 0

  while [[ $elapsed -lt $POD_READY_TIMEOUT ]]; do
    local new_uid=""
    new_uid="$(kctl get pod -n "$SANDBOX_NAMESPACE" "$pod_name" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
    if [[ -n "$new_uid" && "$new_uid" != "$old_uid" ]]; then
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  return 1
}

wait_for_sandbox_ready() {
  local pod_name="$1"
  local elapsed=0
  local interval=5

  while [[ $elapsed -lt $POD_READY_TIMEOUT ]]; do
    local pod_line ready_col phase
    pod_line="$(kctl get pod -n "$SANDBOX_NAMESPACE" "$pod_name" --no-headers 2>/dev/null)" || true
    ready_col="$(printf '%s\n' "$pod_line" | awk '{print $2}')"
    phase="$(printf '%s\n' "$pod_line" | awk '{print $3}')"

    if [[ "$ready_col" == "1/1" && "$phase" == "Running" ]]; then
      return 0
    fi

    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  return 1
}

run_python_core() {
  local sandbox_json=""
  sandbox_json="$(kctl get sandbox "$SANDBOX_NAME" -n "$SANDBOX_NAMESPACE" -o json)"

  GATEWAY_SECRET="$(
    kctl exec -n "$SANDBOX_NAMESPACE" openshell-0 -- printenv OPENSHELL_SSH_HANDSHAKE_SECRET 2>/dev/null       || kctl get statefulset openshell -n "$SANDBOX_NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OPENSHELL_SSH_HANDSHAKE_SECRET")].value}' 2>/dev/null       || true
  )" \
  SANDBOX_SECRET_LIVE="$(kctl exec -n "$SANDBOX_NAMESPACE" "$SANDBOX_NAME" -- printenv OPENSHELL_SSH_HANDSHAKE_SECRET 2>/dev/null || true)" \
  SANDBOX_JSON="$sandbox_json" \
  DEBUG_ENABLED="$DEBUG" \
  REDACT_ENABLED="$REDACT" \
  MODE="$MODE" \
  python3 - <<'PY'
import json
import os
import sys

mode = os.environ["MODE"]
debug_enabled = os.environ["DEBUG_ENABLED"] == "true"
redact_enabled = os.environ["REDACT_ENABLED"] == "true"
gateway_secret = os.environ.get("GATEWAY_SECRET", "")
sandbox_secret_live = os.environ.get("SANDBOX_SECRET_LIVE", "")
sandbox_json = os.environ.get("SANDBOX_JSON", "")

def redact(value: str) -> str:
    if not redact_enabled:
        return value
    if not value:
        return "<unknown>"
    if len(value) <= 8:
        return "<redacted>"
    return "…" + value[-8:]

result = {
    "ok": False,
    "action": None,
    "safe_to_apply": False,
    "changed": False,
    "gateway_secret_present": bool(gateway_secret),
    "sandbox_secret_present": False,
    "gateway_secret_redacted": redact(gateway_secret),
    "sandbox_secret_redacted": "<unknown>",
}

try:
    data = json.loads(sandbox_json)
    env = (
        data.get("spec", {})
            .get("podTemplate", {})
            .get("spec", {})
            .get("containers", [{}])[0]
            .get("env", [])
    )

    sandbox_secret_spec = ""
    sandbox_secret_index = None
    for idx, item in enumerate(env):
        if item.get("name") == "OPENSHELL_SSH_HANDSHAKE_SECRET":
            sandbox_secret_spec = item.get("value", "")
            sandbox_secret_index = idx
            break

    effective_sandbox_secret = sandbox_secret_live or sandbox_secret_spec
    result["sandbox_secret_present"] = bool(effective_sandbox_secret)
    result["sandbox_secret_redacted"] = redact(effective_sandbox_secret)

    if not gateway_secret:
        result["action"] = "error_missing_gateway_secret"
        print(json.dumps(result, indent=2))
        sys.exit(0)

    if not effective_sandbox_secret:
        result["action"] = "error_missing_sandbox_secret"
        print(json.dumps(result, indent=2))
        sys.exit(0)

    if gateway_secret == effective_sandbox_secret:
        result["ok"] = True
        result["action"] = "noop_already_reconciled"
        print(json.dumps(result, indent=2))
        sys.exit(0)

    result["ok"] = True
    result["action"] = "reconcile_sandbox_handshake_secret"
    result["safe_to_apply"] = True

    if sandbox_secret_index is None:
        patch = [{
            "op": "add",
            "path": "/spec/podTemplate/spec/containers/0/env/-",
            "value": {
                "name": "OPENSHELL_SSH_HANDSHAKE_SECRET",
                "value": gateway_secret,
            },
        }]
    else:
        patch = [{
            "op": "replace",
            "path": f"/spec/podTemplate/spec/containers/0/env/{sandbox_secret_index}/value",
            "value": gateway_secret,
        }]

    result["patch_json"] = json.dumps(patch, separators=(",", ":"))

    if debug_enabled and not redact_enabled:
        result["gateway_secret"] = gateway_secret
        result["sandbox_secret"] = effective_sandbox_secret
        result["sandbox_secret_live"] = sandbox_secret_live
        result["sandbox_secret_spec"] = sandbox_secret_spec

    print(json.dumps(result, indent=2))
    sys.exit(0)
except Exception as e:
    result["ok"] = False
    result["action"] = "error_exception"
    if debug_enabled:
        result["error"] = str(e)
    print(json.dumps(result, indent=2))
    sys.exit(10)
PY
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

apply_patch() {
  local patch_json="$1"
  local old_uid=""
  old_uid="$(kctl get pod -n "$SANDBOX_NAMESPACE" "$SANDBOX_NAME" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"

  docker exec "$CONTAINER_NAME" sh -lc \
    "kubectl -n '$SANDBOX_NAMESPACE' patch sandbox '$SANDBOX_NAME' --type='json' -p='${patch_json}'" >/dev/null

  docker exec "$CONTAINER_NAME" sh -lc \
    "kubectl -n '$SANDBOX_NAMESPACE' delete pod '$SANDBOX_NAME' --wait=false" >/dev/null 2>&1 || true

  wait_for_pod_uid_change "$SANDBOX_NAME" "$old_uid" \
    || die "Sandbox '$SANDBOX_NAME' did not rotate to a new pod after handshake reconciliation."

  wait_for_sandbox_ready "$SANDBOX_NAME" \
    || die "Sandbox '$SANDBOX_NAME' did not become ready after handshake reconciliation."
}

emit_text() {
  local json_input="$1"
  JSON_INPUT="$json_input" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["JSON_INPUT"])
action = data.get("action")
gw = data.get("gateway_secret_redacted", "<unknown>")
sb = data.get("sandbox_secret_redacted", "<unknown>")
if action == "noop_already_reconciled":
    print("Sandbox SSH handshake secret already matches the gateway")
    print(f"Gateway secret: {gw}")
    print(f"Sandbox secret: {sb}")
elif action == "applied_reconcile_sandbox_handshake_secret":
    print("Reconciled sandbox SSH handshake secret to match the gateway")
    print(f"Gateway secret: {gw}")
elif action == "reconcile_sandbox_handshake_secret":
    print("Sandbox SSH handshake secret drift detected")
    print(f"Gateway secret: {gw}")
    print(f"Sandbox secret: {sb}")
else:
    print("Could not reconcile sandbox SSH handshake state automatically")
    print(f"Action: {action}")
PY
}

main() {
  parse_args "$@"
  need_cmd docker
  need_cmd python3
  require_running_container

  local result_json=""
  result_json="$(run_python_core)"

  local action=""
  local safe_to_apply=""
  local patch_json=""
  action="$(json_get "$result_json" "action")"
  safe_to_apply="$(json_get "$result_json" "safe_to_apply")"
  patch_json="$(json_get "$result_json" "patch_json")"

  if [[ "$MODE" == "--apply" && "$action" == "reconcile_sandbox_handshake_secret" && "$safe_to_apply" == "true" ]]; then
    apply_patch "$patch_json"
    result_json="$(JSON_INPUT="$result_json" python3 - <<'PY'
import json, os
r = json.loads(os.environ["JSON_INPUT"])
r["action"] = "applied_reconcile_sandbox_handshake_secret"
r["changed"] = True
print(json.dumps(r, indent=2))
PY
)"
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