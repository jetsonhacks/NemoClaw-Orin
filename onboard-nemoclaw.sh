#!/usr/bin/env bash
set -Eeuo pipefail

# Run NemoClaw onboarding in a more controlled way.
# Assumes setup-jetson-orin.sh has already been run.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$HOME/.config/openshell/jetson-orin.env}"
PATCHED_IMAGE_NAME_DEFAULT="openshell-cluster:jetson-legacy-0.0.12"
DOCKERFILE_PATH="${DOCKERFILE_PATH:-$SCRIPT_DIR/image/Dockerfile.openshell-cluster-legacy}"
FREE_PORT_CHECK_ONLY="${FREE_PORT_CHECK_ONLY:-false}"
STOP_HOST_K3S="${STOP_HOST_K3S:-true}"
REQUIRE_NODE_MAJOR="${REQUIRE_NODE_MAJOR:-22}"
MIN_SWAP_GB="${MIN_SWAP_GB:-8}"

log() { printf '\n==> %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

source_env_file() {
  if [[ -f "$HOME/.bashrc" ]]; then
    # shellcheck disable=SC1090
    source "$HOME/.bashrc" || true
  fi

  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  fi

  export OPENSHELL_CLUSTER_IMAGE="${OPENSHELL_CLUSTER_IMAGE:-$PATCHED_IMAGE_NAME_DEFAULT}"
}

check_tooling() {
  need_cmd docker
  need_cmd openshell
  need_cmd nemoclaw
  need_cmd node
  need_cmd npm
  need_cmd sudo

  docker info >/dev/null 2>&1 || die "Docker daemon is not running or not accessible."

  local node_major
  node_major="$(node -p 'process.versions.node.split(".")[0]')"
  [[ "$node_major" =~ ^[0-9]+$ ]] || die "Unable to determine Node.js major version."
  (( node_major == REQUIRE_NODE_MAJOR )) || die "Node.js major version $REQUIRE_NODE_MAJOR is required; found $(node --version)."
}

show_resource_state() {
  log "Current memory and swap"
  free -h
  swapon --show || true

  local swap_gb
  swap_gb="$(swapon --bytes --noheadings --show=SIZE 2>/dev/null | awk '{sum += $1} END {printf "%.2f", sum/1024/1024/1024}')"
  if [[ -n "$swap_gb" ]] && awk "BEGIN {exit !($swap_gb < $MIN_SWAP_GB)}"; then
    warn "Total swap appears below ${MIN_SWAP_GB} GiB. NemoClaw docs warn that sandbox image push/import can trigger OOM on low-memory systems."
  fi
}

maybe_stop_host_k3s() {
  if [[ "$STOP_HOST_K3S" != "true" ]]; then
    warn "Leaving host k3s running (STOP_HOST_K3S=$STOP_HOST_K3S)."
    return 0
  fi

  if systemctl is-active --quiet k3s; then
    log "Stopping host k3s to reduce memory pressure during onboarding"
    sudo systemctl stop k3s
  else
    log "Host k3s is already stopped"
  fi
}

free_conflicting_ports() {
  log "Cleaning up any previous NemoClaw/OpenShell session"
  openshell forward stop 18789 2>/dev/null || true
  # Use stop rather than destroy to preserve the locally-built cluster image.
  # openshell gateway destroy removes the image from Docker's store, which
  # causes the next onboarding run to fail with "image not found locally".
  openshell gateway stop -g nemoclaw 2>/dev/null || true
  openshell gateway stop -g openshell 2>/dev/null || true

  log "Checking required ports"
  sudo lsof -i :8080 -sTCP:LISTEN || true
  sudo lsof -i :18789 -sTCP:LISTEN || true

  if [[ "$FREE_PORT_CHECK_ONLY" == "true" ]]; then
    log "FREE_PORT_CHECK_ONLY=true; stopping before onboarding"
    exit 0
  fi
}

check_openshell_image_override() {
  log "Using OpenShell cluster image override"
  printf 'OPENSHELL_CLUSTER_IMAGE=%s\n' "$OPENSHELL_CLUSTER_IMAGE"
  docker image inspect "$OPENSHELL_CLUSTER_IMAGE" >/dev/null 2>&1 || die "OpenShell cluster image not found locally: $OPENSHELL_CLUSTER_IMAGE"
  docker run --rm --entrypoint sh "$OPENSHELL_CLUSTER_IMAGE" -lc 'iptables --version' | grep -q '(legacy)' || \
    die "Patched OpenShell cluster image is not using legacy iptables."
}

rebuild_cluster_image() {
  # nemoclaw onboard's preflight may call openshell gateway destroy, which
  # removes locally-built images from Docker's store. Rebuilding immediately
  # before handing off to nemoclaw onboard ensures the image is always present
  # when the gateway start is attempted. The build is fast from Docker cache.
  [[ -f "$DOCKERFILE_PATH" ]] || die "Dockerfile not found: $DOCKERFILE_PATH"

  # Extract the version from the image tag, e.g. openshell-cluster:jetson-legacy-0.0.13 -> 0.0.13
  local cluster_version
  cluster_version="${OPENSHELL_CLUSTER_IMAGE##*-}"
  [[ -n "$cluster_version" ]] || die "Could not extract cluster version from OPENSHELL_CLUSTER_IMAGE=$OPENSHELL_CLUSTER_IMAGE"

  log "Rebuilding cluster image before onboarding: $OPENSHELL_CLUSTER_IMAGE"
  # Build context is the image/ directory so COPY patch-entrypoint.sh resolves correctly.
  docker build \
    --build-arg "CLUSTER_VERSION=$cluster_version" \
    -t "$OPENSHELL_CLUSTER_IMAGE" \
    -f "$DOCKERFILE_PATH" \
    "$(dirname "$DOCKERFILE_PATH")"
}

run_onboarding() {
  log "Starting NemoClaw onboarding"
  log "OpenShell/NemoClaw will inherit OPENSHELL_CLUSTER_IMAGE from this shell"
  nemoclaw onboard
}

print_recovery_hints() {
  cat <<'EOF_HINTS'

If onboarding fails:

  dmesg -T | grep -i -E 'killed process|out of memory|oom'
  free -h
  swapon --show
  docker ps -a
  openshell status || true

EOF_HINTS
}

main() {
  source_env_file
  check_tooling
  show_resource_state
  maybe_stop_host_k3s
  free_conflicting_ports
  check_openshell_image_override
  rebuild_cluster_image
  print_recovery_hints
  run_onboarding
}

main "$@"