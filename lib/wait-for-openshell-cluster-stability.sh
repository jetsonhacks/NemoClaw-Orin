#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$ROOT_DIR/lib/script-ui.sh" ]]; then
  # shellcheck disable=SC1090
  source "$ROOT_DIR/lib/script-ui.sh"
else
  QUIET="${QUIET:-false}"
  VERBOSE="${VERBOSE:-false}"
  DEBUG="${DEBUG:-false}"
  ui_step() { [[ "${QUIET:-false}" == "true" ]] || printf '\n==> %s\n' "$*"; }
  ui_info() { [[ "${QUIET:-false}" == "true" ]] || printf '%s\n' "$*"; }
  ui_warn() { [[ "${QUIET:-false}" == "true" ]] || printf '\n[WARN] %s\n' "$*" >&2; }
  ui_error() { printf '\n[ERROR] %s\n' "$*" >&2; }
  die() { ui_error "$*"; return 1 2>/dev/null || exit 1; }
  need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }
fi

GATEWAY_NAME="${GATEWAY_NAME:-nemoclaw}"
CONTAINER_NAME="${CONTAINER_NAME:-openshell-cluster-${GATEWAY_NAME}}"
OPENSHHELL_NAMESPACE_DEFAULT="openshell"
OPENSHHELL_SYSTEM_NAMESPACE_DEFAULT="kube-system"
SANDBOX_NAME=""
OPENSHHELL_NAMESPACE="${OPENSHHELL_NAMESPACE:-$OPENSHHELL_NAMESPACE_DEFAULT}"
SYSTEM_NAMESPACE="${SYSTEM_NAMESPACE:-$OPENSHHELL_SYSTEM_NAMESPACE_DEFAULT}"
CORE_DNS_LABEL="${CORE_DNS_LABEL:-k8s-app=kube-dns}"
OPENSHELL_POD_NAME="${OPENSHELL_POD_NAME:-openshell-0}"
TIMEOUT="${TIMEOUT:-180}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
QUIET_PERIOD="${QUIET_PERIOD:-20}"
SKIP_DNS_PROBE="${SKIP_DNS_PROBE:-false}"
QUIET="${QUIET:-false}"
VERBOSE="${VERBOSE:-false}"
DEBUG="${DEBUG:-false}"

usage() {
  cat <<'EOF_USAGE'
Usage:
  ./lib/wait-for-openshell-cluster-stability.sh <sandbox-name> [flags]

Flags:
  --timeout <seconds>        Overall timeout (default: 180)
  --poll-interval <seconds>  Poll interval (default: 5)
  --quiet-period <seconds>   No recent churn events required before success (default: 20)
  --skip-dns-probe           Skip DNS lookup from inside the sandbox
  --quiet
  --verbose
  --debug
  -h, --help

What it checks:
  - OpenShell gateway container is running
  - CoreDNS pod(s) in kube-system are Ready
  - openshell-0 pod is Ready in the openshell namespace
  - sandbox pod is Ready in the openshell namespace
  - sandbox can resolve openshell.openshell.svc.cluster.local (unless skipped)
  - recent cluster events do not show fresh churn within the quiet period
EOF_USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout)
        [[ $# -ge 2 ]] || die "Missing value for --timeout"
        TIMEOUT="$2"
        shift 2
        ;;
      --poll-interval)
        [[ $# -ge 2 ]] || die "Missing value for --poll-interval"
        POLL_INTERVAL="$2"
        shift 2
        ;;
      --quiet-period)
        [[ $# -ge 2 ]] || die "Missing value for --quiet-period"
        QUIET_PERIOD="$2"
        shift 2
        ;;
      --skip-dns-probe)
        SKIP_DNS_PROBE="true"
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

kctl() {
  docker exec "$CONTAINER_NAME" kubectl "$@"
}

container_running() {
  local state
  state="$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  [[ "$state" == "running" ]]
}

pods_matching_label_ready() {
  local namespace="$1"
  local label="$2"
  local output ready_count total_count

  output="$(kctl -n "$namespace" get pods -l "$label" --no-headers 2>/dev/null || true)"
  [[ -n "$output" ]] || return 1

  total_count="$(printf '%s\n' "$output" | sed '/^\s*$/d' | wc -l | tr -d ' ')"
  ready_count="$(printf '%s\n' "$output" | awk '{if ($2 ~ /^[0-9]+\/[0-9]+$/) {split($2,a,"/"); if (a[1]==a[2] && $3=="Running") ok++}} END {print ok+0}')"

  [[ "$total_count" -gt 0 && "$ready_count" -eq "$total_count" ]]
}

pod_ready() {
  local namespace="$1"
  local pod_name="$2"
  local line ready phase

  line="$(kctl -n "$namespace" get pod "$pod_name" --no-headers 2>/dev/null || true)"
  [[ -n "$line" ]] || return 1

  ready="$(printf '%s\n' "$line" | awk '{print $2}')"
  phase="$(printf '%s\n' "$line" | awk '{print $3}')"
  [[ "$ready" == "1/1" && "$phase" == "Running" ]]
}

sandbox_dns_resolves() {
  kctl -n "$OPENSHHELL_NAMESPACE" exec "$SANDBOX_NAME" -- sh -lc 'getent hosts openshell.openshell.svc.cluster.local >/dev/null' >/dev/null 2>&1
}

recent_churn_detected() {
  local events now_epoch threshold epoch
  now_epoch="$(date +%s)"
  threshold=$((now_epoch - QUIET_PERIOD))

  events="$(kctl get events -A --sort-by=.lastTimestamp 2>/dev/null | tail -n 80 || true)"
  [[ -n "$events" ]] || return 1

  while IFS= read -r line; do
    [[ "$line" == *"SandboxChanged"* || "$line" == *"BackOff"* || "$line" == *"Unhealthy"* || "$line" == *"Failed"* || "$line" == *"Killing"* ]] || continue

    epoch="$(EVENT_LINE="$line" python3 - <<'PY'
import os, re
line = os.environ.get('EVENT_LINE','')
m = re.search(r'(^|\s)(\d+)m($|\s)', line)
if m:
    print(int(m.group(2))*60)
    raise SystemExit
m = re.search(r'(^|\s)(\d+)s($|\s)', line)
if m:
    print(int(m.group(2)))
    raise SystemExit
print(-1)
PY
)"
    if [[ "$epoch" =~ ^[0-9]+$ ]] && [[ "$epoch" -le "$QUIET_PERIOD" ]]; then
      return 0
    fi
  done <<< "$events"

  return 1
}

show_debug_snapshot() {
  [[ "$DEBUG" == "true" ]] || return 0

  echo ""
  echo "--- openshell pods ---"
  kctl -n "$OPENSHHELL_NAMESPACE" get pods -o wide || true

  echo ""
  echo "--- kube-system pods ---"
  kctl -n "$SYSTEM_NAMESPACE" get pods -o wide || true

  echo ""
  echo "--- recent cluster events ---"
  kctl get events -A --sort-by=.lastTimestamp | tail -n 50 || true
}

main() {
  parse_args "$@"

  need_cmd docker
  need_cmd python3

  ui_step "Waiting for OpenShell cluster stability"

  local deadline now
  deadline=$(( $(date +%s) + TIMEOUT ))

  while true; do
    now="$(date +%s)"
    if (( now >= deadline )); then
      ui_warn "Timed out waiting for OpenShell cluster stability."
      show_debug_snapshot
      exit 1
    fi

    if ! container_running; then
      [[ "$VERBOSE" == "true" || "$DEBUG" == "true" ]] && ui_info "Gateway container is not running yet."
      sleep "$POLL_INTERVAL"
      continue
    fi

    if ! pods_matching_label_ready "$SYSTEM_NAMESPACE" "$CORE_DNS_LABEL"; then
      [[ "$VERBOSE" == "true" || "$DEBUG" == "true" ]] && ui_info "CoreDNS is not Ready yet."
      sleep "$POLL_INTERVAL"
      continue
    fi

    if ! pod_ready "$OPENSHHELL_NAMESPACE" "$OPENSHELL_POD_NAME"; then
      [[ "$VERBOSE" == "true" || "$DEBUG" == "true" ]] && ui_info "${OPENSHELL_POD_NAME} is not Ready yet."
      sleep "$POLL_INTERVAL"
      continue
    fi

    if ! pod_ready "$OPENSHHELL_NAMESPACE" "$SANDBOX_NAME"; then
      [[ "$VERBOSE" == "true" || "$DEBUG" == "true" ]] && ui_info "Sandbox pod ${SANDBOX_NAME} is not Ready yet."
      sleep "$POLL_INTERVAL"
      continue
    fi

    if [[ "$SKIP_DNS_PROBE" != "true" ]]; then
      if ! sandbox_dns_resolves; then
        [[ "$VERBOSE" == "true" || "$DEBUG" == "true" ]] && ui_info "Sandbox DNS lookup for openshell.openshell.svc.cluster.local is not ready yet."
        sleep "$POLL_INTERVAL"
        continue
      fi
    fi

    if recent_churn_detected; then
      [[ "$VERBOSE" == "true" || "$DEBUG" == "true" ]] && ui_info "Recent churn events are still within the quiet period."
      sleep "$POLL_INTERVAL"
      continue
    fi

    break
  done

  if [[ "$QUIET" != "true" ]]; then
    echo ""
    echo "OpenShell cluster stability checks passed."
    echo ""
    echo "Ready:" 
    echo "  - CoreDNS"
    echo "  - ${OPENSHELL_POD_NAME}"
    echo "  - ${SANDBOX_NAME}"
    if [[ "$SKIP_DNS_PROBE" != "true" ]]; then
      echo "  - sandbox DNS resolution for openshell.openshell.svc.cluster.local"
    fi
    echo "  - no fresh churn events in the last ${QUIET_PERIOD}s"
  fi
}

main "$@"
