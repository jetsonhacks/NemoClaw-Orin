#!/usr/bin/env bash
set -Eeuo pipefail

# restart-nemoclaw.sh — Resume NemoClaw after a reboot or a stopped gateway
#
# DO NOT use `openshell gateway start` to resume NemoClaw after a reboot.
# That command defaults to creating/starting a gateway named 'openshell',
# not the 'nemoclaw' gateway. Running it against a stopped nemoclaw container
# creates a second gateway that conflicts on port 8080, corrupts state,
# and requires a full re-onboard to recover.
#
# This script:
#   1. Sources the OpenShell environment override (OPENSHELL_CLUSTER_IMAGE)
#   2. Starts the gateway container directly via Docker
#   3. Selects the nemoclaw gateway in the OpenShell CLI
#   4. Waits for the gateway API to become ready
#   5. Waits for openshell-0 and da-claw pods to be Ready
#   6. Lists available sandboxes
#
# Note on the SSH handshake secret:
#   The patched cluster image (Dockerfile.openshell-cluster-legacy) persists
#   the SSH handshake secret to the k3s volume on first start and reloads it
#   on subsequent starts. This means openshell-0 and da-claw always share the
#   same secret after a restart — no manual secret syncing is needed here.
#   See docs/fix-handshake-secret.md for the full explanation.
#
# Usage:
#   ./restart-nemoclaw.sh
#
# Optional environment overrides:
#   GATEWAY_NAME=nemoclaw        Gateway name (default: nemoclaw)
#   CONTAINER_NAME=              Override container name (default: openshell-cluster-<GATEWAY_NAME>)
#   SANDBOX_NAME=da-claw         Sandbox pod name (default: da-claw)
#   SANDBOX_NAMESPACE=openshell  Kubernetes namespace (default: openshell)
#   ENV_FILE=~/.config/openshell/jetson-orin.env
#   GATEWAY_READY_TIMEOUT=90     Seconds to wait for gateway API (default: 90)
#   POD_READY_TIMEOUT=120        Seconds to wait for pod readiness (default: 120)

GATEWAY_NAME="${GATEWAY_NAME:-nemoclaw}"
CONTAINER_NAME="${CONTAINER_NAME:-openshell-cluster-${GATEWAY_NAME}}"
SANDBOX_NAME="${SANDBOX_NAME:-da-claw}"
SANDBOX_NAMESPACE="${SANDBOX_NAMESPACE:-openshell}"
ENV_FILE="${ENV_FILE:-$HOME/.config/openshell/jetson-orin.env}"
GATEWAY_READY_TIMEOUT="${GATEWAY_READY_TIMEOUT:-90}"
POD_READY_TIMEOUT="${POD_READY_TIMEOUT:-120}"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

kctl() { docker exec "$CONTAINER_NAME" kubectl "$@" 2>/dev/null; }

# ── Step 1: Source env file ────────────────────────────────────────────────────

log "Step 1: Loading OpenShell environment"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  printf 'OPENSHELL_CLUSTER_IMAGE=%s\n' "${OPENSHELL_CLUSTER_IMAGE:-<not set>}"
else
  warn "Env file not found: $ENV_FILE"
  warn "OPENSHELL_CLUSTER_IMAGE may not be set. Run setup-jetson-orin.sh if this is a fresh install."
fi

# ── Step 2: Verify container exists ───────────────────────────────────────────

log "Step 2: Checking gateway container"

if ! docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
  die "Container '$CONTAINER_NAME' not found. The gateway may have been destroyed. Run onboard-nemoclaw.sh to recreate it."
fi

container_status="$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME")"
printf 'Container: %s  Status: %s\n' "$CONTAINER_NAME" "$container_status"

# ── Step 3: Start the container ───────────────────────────────────────────────

log "Step 3: Starting gateway container"

if [[ "$container_status" == "running" ]]; then
  printf 'Container is already running — skipping docker start\n'
else
  docker start "$CONTAINER_NAME"
  printf 'Container started\n'
fi

# ── Step 4: Select the gateway ────────────────────────────────────────────────

log "Step 4: Selecting gateway '$GATEWAY_NAME'"
openshell gateway select "$GATEWAY_NAME"

# ── Step 5: Wait for gateway API to be ready ──────────────────────────────────

log "Step 5: Waiting for gateway API to become ready (timeout: ${GATEWAY_READY_TIMEOUT}s)"

elapsed=0
interval=5

while [[ $elapsed -lt $GATEWAY_READY_TIMEOUT ]]; do
  if openshell status >/dev/null 2>&1; then
    printf 'Gateway API is ready\n'
    break
  fi
  printf 'Waiting... (%ds elapsed)\n' "$elapsed"
  sleep "$interval"
  elapsed=$((elapsed + interval))
done

openshell status >/dev/null 2>&1 \
  || die "Gateway did not become ready within ${GATEWAY_READY_TIMEOUT}s. Check: docker logs $CONTAINER_NAME"

openshell gateway info

# ── Step 6: Wait for openshell-0 to be 1/1 Ready ─────────────────────────────

log "Step 6: Waiting for openshell-0 to be 1/1 Ready (timeout: ${POD_READY_TIMEOUT}s)"

elapsed=0
cp_ready=false

while [[ $elapsed -lt $POD_READY_TIMEOUT ]]; do
  ready_col="$(kctl get pod -n "$SANDBOX_NAMESPACE" openshell-0 --no-headers \
    | awk '{print $2}')" || true
  if [[ "$ready_col" == "1/1" ]]; then
    cp_ready=true
    printf 'openshell-0 is 1/1 Ready\n'
    break
  fi
  printf 'openshell-0 ready: %s — waiting... (%ds elapsed)\n' "${ready_col:-unknown}" "$elapsed"
  sleep "$interval"
  elapsed=$((elapsed + interval))
done

[[ "$cp_ready" == "true" ]] \
  || die "openshell-0 did not become Ready within ${POD_READY_TIMEOUT}s. Check: docker logs $CONTAINER_NAME"

# ── Step 7: Wait for sandbox pod to be 1/1 Ready ─────────────────────────────

log "Step 7: Waiting for sandbox pod '$SANDBOX_NAME' to be 1/1 Ready (timeout: ${POD_READY_TIMEOUT}s)"

elapsed=0
sb_ready=false

while [[ $elapsed -lt $POD_READY_TIMEOUT ]]; do
  pod_line="$(kctl get pod -n "$SANDBOX_NAMESPACE" "$SANDBOX_NAME" --no-headers 2>/dev/null)" || true
  ready_col="$(printf '%s\n' "$pod_line" | awk '{print $2}')"
  restart_count="$(printf '%s\n' "$pod_line" | awk '{print $4}')"

  if [[ "$ready_col" == "1/1" ]]; then
    sb_ready=true
    printf 'Sandbox pod Ready (restarts: %s)\n' "${restart_count:-0}"
    if [[ "${restart_count:-0}" -gt 0 ]]; then
      warn "Pod has ${restart_count} restart(s). If 'nemoclaw da-claw connect' fails,"
      warn "the patched cluster image may not be in use. Check: docker inspect $CONTAINER_NAME | grep Image"
      warn "If the image is wrong, rebuild it and run onboard-nemoclaw.sh."
    fi
    break
  fi

  printf 'Sandbox pod ready: %s restarts: %s — waiting... (%ds elapsed)\n' \
    "${ready_col:-unknown}" "${restart_count:-?}" "$elapsed"
  sleep "$interval"
  elapsed=$((elapsed + interval))
done

[[ "$sb_ready" == "true" ]] || {
  warn "Sandbox pod did not become Ready within ${POD_READY_TIMEOUT}s."
  warn "Check: docker exec $CONTAINER_NAME kubectl logs -n $SANDBOX_NAMESPACE $SANDBOX_NAME"
}

# ── Step 8: List sandboxes ────────────────────────────────────────────────────

log "Step 8: Available sandboxes"
openshell sandbox list || warn "Could not list sandboxes — the gateway may still be initializing"

# ── Done ───────────────────────────────────────────────────────────────────────

echo ""
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "  NemoClaw gateway is running."
echo ""
echo "  Connect to your sandbox:"
echo "    nemoclaw da-claw connect"
echo ""
echo "──────────────────────────────────────────────────────────────"
echo ""
echo ""
echo "  REMINDER: Never use 'openshell gateway start' to resume"
echo "  NemoClaw. Always use this script."
echo ""
echo ""