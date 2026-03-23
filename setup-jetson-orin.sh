#!/usr/bin/env bash
set -Eeuo pipefail

# Prepare a Jetson Orin host for OpenShell/NemoClaw by:
# - installing or verifying the required host-side tools
# - running the reusable host-prereqs helper
# - verifying Docker / bridge netfilter / host iptables state
# - discovering the latest upstream OpenShell cluster version
# - building a patched OpenShell cluster image that uses iptables-legacy
# - writing an environment file that exports OPENSHELL_CLUSTER_IMAGE
#
# This script does NOT run `openshell gateway start` or `nemoclaw onboard`.
# Keep the heavier onboarding phase separate so failures are easier to debug.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKERFILE_PATH="${DOCKERFILE_PATH:-$SCRIPT_DIR/image/Dockerfile.openshell-cluster-legacy}"
UPDATE_CHECKER_PATH="${UPDATE_CHECKER_PATH:-$SCRIPT_DIR/lib/check-openshell-cluster-update.sh}"
HOST_PREREQS_SCRIPT="${HOST_PREREQS_SCRIPT:-$SCRIPT_DIR/lib/setup-openshell-host-prereqs.sh}"
PATCHED_IMAGE_NAME_PREFIX="${PATCHED_IMAGE_NAME_PREFIX:-openshell-cluster:jetson-legacy}"
ENV_FILE="${ENV_FILE:-$HOME/.config/openshell/jetson-orin.env}"
REQUIRE_LEGACY_HOST_IPTABLES="${REQUIRE_LEGACY_HOST_IPTABLES:-true}"
DEFAULT_CLUSTER_VERSION="${DEFAULT_CLUSTER_VERSION:-0.0.12}"
NODE_MAJOR="${NODE_MAJOR:-22}"
OPENSHELL_INSTALL_URL="${OPENSHELL_INSTALL_URL:-https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh}"
OPENSHELL_VERSION="${OPENSHELL_VERSION:-v0.0.13}"
NEMOCLAW_CLONE_URL="${NEMOCLAW_CLONE_URL:-https://github.com/NVIDIA/NemoClaw.git}"
OPENSHELL_CLUSTER_VERSION=""
PATCHED_IMAGE_NAME=""

log() { printf '\n==> %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

usage() {
  cat <<'EOF_USAGE'
Usage:
  ./setup-jetson-orin.sh

Environment overrides:
  HOST_PREREQS_SCRIPT=/path/to/script      Override helper path
  REQUIRE_LEGACY_HOST_IPTABLES=true|false  Require host iptables to report '(legacy)' (default: true)
  PATCHED_IMAGE_NAME_PREFIX=name:tagprefix Override local patched image tag prefix
  DEFAULT_CLUSTER_VERSION=x.y.z            Fallback if update checker is unavailable
  NODE_MAJOR=22                            Node.js major line to install if missing
  OPENSHELL_INSTALL_URL=https://...        Override the OpenShell install script URL
  OPENSHELL_VERSION=v0.0.13                OpenShell CLI version to install if missing
  NEMOCLAW_CLONE_URL=https://...           Override the NemoClaw git repository URL
EOF_USAGE
}

ensure_line_in_file() {
  local line="$1"
  local file="$2"
  touch "$file"
  grep -Fqx "$line" "$file" || printf '%s\n' "$line" >> "$file"
}

ensure_local_bin_on_path() {
  local local_bin="$HOME/.local/bin"
  if [[ -d "$local_bin" && ":$PATH:" != *":$local_bin:"* ]]; then
    export PATH="$local_bin:$PATH"
  fi
}

ensure_npm_bin_on_path() {
  local npm_bin
  npm_bin="$(npm config get prefix 2>/dev/null)/bin"
  if [[ -d "$npm_bin" && ":$PATH:" != *":$npm_bin:"* ]]; then
    export PATH="$npm_bin:$PATH"
  fi
}

install_nodejs_if_needed() {
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    log "Node.js and npm already installed"
    printf 'node: %s\n' "$(node --version)"
    printf 'npm:  %s\n' "$(npm --version)"
    return 0
  fi

  need_cmd sudo
  need_cmd curl
  need_cmd apt-get

  log "Installing Node.js ${NODE_MAJOR}.x and npm"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo bash -
  sudo apt-get install -y nodejs

  command -v node >/dev/null 2>&1 || die "Node.js installation completed but 'node' was not found in PATH."
  command -v npm >/dev/null 2>&1 || die "Node.js installation completed but 'npm' was not found in PATH."

  printf 'node: %s\n' "$(node --version)"
  printf 'npm:  %s\n' "$(npm --version)"
}

install_openshell_if_needed() {
  ensure_local_bin_on_path

  if command -v openshell >/dev/null 2>&1; then
    log "OpenShell CLI already installed"
    openshell --version
    return 0
  fi

  need_cmd curl
  need_cmd sh

  log "Installing OpenShell CLI with the upstream install script"
  curl -LsSf "$OPENSHELL_INSTALL_URL" | OPENSHELL_VERSION="$OPENSHELL_VERSION" sh
  ensure_local_bin_on_path
  ensure_line_in_file 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.bashrc"

  command -v openshell >/dev/null 2>&1 || die "OpenShell installed but 'openshell' is not in PATH. Open a new shell or source ~/.bashrc and retry."
  openshell --version
}

patch_nemoclaw_onboard() {
  # NemoClaw v0.1.0 unconditionally overwrites OPENSHELL_CLUSTER_IMAGE with
  # the upstream ghcr.io image, ignoring any value already set in the
  # environment. On Jetson we need the patched local image (iptables-legacy)
  # or the gateway container crashes at startup. This patch makes NemoClaw
  # respect a pre-set OPENSHELL_CLUSTER_IMAGE.
  #
  # Called against the local clone before npm link. The clone must remain in
  # place permanently — nemoclaw onboard stages its Docker build context from
  # the clone directory at runtime and requires the full source tree.
  #
  # The patch is idempotent: it checks for the already-patched string before
  # applying, so re-running setup is safe.

  local clone_dir="$1"
  local target="$clone_dir/bin/lib/onboard.js"

  [[ -f "$target" ]] || die "Cannot patch NemoClaw onboard: file not found: $target"

  local needle='if (stableGatewayImage && openshellVersion) {'
  local patched='if (stableGatewayImage && openshellVersion && !process.env.OPENSHELL_CLUSTER_IMAGE) {'

  if grep -qF "$patched" "$target"; then
    log "NemoClaw onboard patch already applied — skipping"
    return 0
  fi

  if ! grep -qF "$needle" "$target"; then
    warn "NemoClaw onboard patch: expected string not found in $target"
    warn "The NemoClaw source may have changed — review manually:"
    warn "  $target"
    warn "Look for the block that sets gatewayEnv.OPENSHELL_CLUSTER_IMAGE"
    warn "and add '&& !process.env.OPENSHELL_CLUSTER_IMAGE' to the condition."
    return 0
  fi

  log "Patching NemoClaw onboard to respect OPENSHELL_CLUSTER_IMAGE"
  # Escape & in the replacement string — sed interprets & as "the whole match"
  local patched_escaped="${patched//&/\\&}"
  sed -i "s|${needle}|${patched_escaped}|" "$target"

  grep -qF "$patched" "$target" || die "Patch was applied but verification failed — check $target manually"
  printf 'Patched: %s\n' "$target"
}

install_nemoclaw_if_needed() {
  if command -v nemoclaw >/dev/null 2>&1; then
    log "NemoClaw CLI already installed"
    printf 'nemoclaw: %s\n' "$(command -v nemoclaw)"
    return
  fi

  # npm install -g with the git+https spec fails on this platform — npm's
  # git fetch path produces a broken install. The workaround is to clone
  # locally, patch, then npm link. The clone directory must remain in place
  # permanently: nemoclaw onboard stages its Docker build context from the
  # clone at runtime and requires the full source tree.

  need_cmd git

  local clone_dir="$HOME/NemoClaw"
  local nemoclaw_repo="${NEMOCLAW_CLONE_URL:-https://github.com/NVIDIA/NemoClaw.git}"

  log "Installing NemoClaw CLI"
  printf 'Clone target: %s\n' "$clone_dir"
  printf 'Repository:   %s\n' "$nemoclaw_repo"

  if [[ -d "$clone_dir" ]]; then
    warn "Clone directory already exists: $clone_dir"
    warn "Pulling latest changes instead of cloning fresh"
    git -C "$clone_dir" pull --ff-only || \
      die "git pull failed in $clone_dir — resolve conflicts or remove the directory and retry"
  else
    git clone "$nemoclaw_repo" "$clone_dir"
  fi

  # Patch before linking so the installed command reflects the fix
  patch_nemoclaw_onboard "$clone_dir"

  (
    cd "$clone_dir"
    npm install --ignore-scripts
    npm link --ignore-scripts
  )

  ensure_npm_bin_on_path
  ensure_local_bin_on_path

  command -v nemoclaw >/dev/null 2>&1 || \
    die "NemoClaw installed but 'nemoclaw' not found in PATH. npm global bin may not be on PATH — check: npm config get prefix"

  local npm_bin
  npm_bin="$(npm config get prefix)/bin"
  ensure_line_in_file "export PATH=\"$npm_bin:\$PATH\"" "$HOME/.bashrc"
  ensure_line_in_file 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.bashrc"

  hash -r 2>/dev/null || true
  printf 'nemoclaw: %s\n' "$(command -v nemoclaw)"
}

run_host_prereqs() {
  [[ -x "$HOST_PREREQS_SCRIPT" ]] || die "Host prereqs helper is not executable: $HOST_PREREQS_SCRIPT"

  log "Running host prerequisite helper"
  "$HOST_PREREQS_SCRIPT"
}

ensure_docker_running() {
  need_cmd docker
  docker info >/dev/null 2>&1 || die "Docker daemon is not running or not accessible."
}

verify_host_state() {
  log "Verifying host Docker / cgroup / iptables state"
  docker info | sed -n '/Cgroup/,+8p'
  iptables --version
  update-alternatives --display iptables || true
  lsmod | grep -E 'br_netfilter|iptable_filter|iptable_nat|ip_tables|nf_tables' || true
  sysctl net.bridge.bridge-nf-call-iptables
  sysctl net.bridge.bridge-nf-call-ip6tables

  if [[ "$REQUIRE_LEGACY_HOST_IPTABLES" == "true" ]]; then
    iptables --version | grep -q '(legacy)' || die "Host iptables is not using legacy backend."
  fi
}

discover_cluster_version() {
  if [[ -x "$UPDATE_CHECKER_PATH" ]]; then
    log "Discovering latest OpenShell cluster version"
    OPENSHELL_CLUSTER_VERSION="$($UPDATE_CHECKER_PATH --latest-version)" || \
      die "Failed to determine latest OpenShell cluster version via $UPDATE_CHECKER_PATH"
  else
    warn "Update checker not executable: $UPDATE_CHECKER_PATH"
    warn "Falling back to DEFAULT_CLUSTER_VERSION=$DEFAULT_CLUSTER_VERSION"
    OPENSHELL_CLUSTER_VERSION="$DEFAULT_CLUSTER_VERSION"
  fi

  [[ -n "$OPENSHELL_CLUSTER_VERSION" ]] || die "OpenShell cluster version is empty."
  PATCHED_IMAGE_NAME="${PATCHED_IMAGE_NAME_PREFIX}-${OPENSHELL_CLUSTER_VERSION}"

  printf 'Using upstream OpenShell cluster version: %s\n' "$OPENSHELL_CLUSTER_VERSION"
  printf 'Will build patched local image: %s\n' "$PATCHED_IMAGE_NAME"
}

build_patched_cluster_image() {
  [[ -f "$DOCKERFILE_PATH" ]] || die "Dockerfile not found: $DOCKERFILE_PATH"
  log "Building patched OpenShell cluster image: $PATCHED_IMAGE_NAME"
  # Build context is the image/ directory so COPY patch-entrypoint.sh resolves correctly.
  docker build \
    --build-arg "CLUSTER_VERSION=$OPENSHELL_CLUSTER_VERSION" \
    -t "$PATCHED_IMAGE_NAME" \
    -f "$DOCKERFILE_PATH" \
    "$(dirname "$DOCKERFILE_PATH")"
}

write_env_file() {
  mkdir -p "$(dirname "$ENV_FILE")"

  log "Writing OpenShell environment file: $ENV_FILE"
  cat > "$ENV_FILE" <<EOF_ENV
export OPENSHELL_CLUSTER_IMAGE="$PATCHED_IMAGE_NAME"
EOF_ENV

  # Auto-source the env file in new shells
  ensure_line_in_file "source \"$ENV_FILE\"" "$HOME/.bashrc"

  printf 'Wrote: %s\n' "$ENV_FILE"
  printf 'To use it in the current shell: source %s\n' "$ENV_FILE"
}

main() {
  case "${1:-}" in
    -h|--help)
      usage
      exit 0
      ;;
  esac

  install_nodejs_if_needed
  install_openshell_if_needed
  install_nemoclaw_if_needed
  run_host_prereqs
  ensure_docker_running
  verify_host_state
  discover_cluster_version
  build_patched_cluster_image
  write_env_file

  log "Jetson Orin host setup complete"
  printf 'Patched cluster image: %s\n' "$PATCHED_IMAGE_NAME"
  printf 'OpenShell env file:    %s\n' "$ENV_FILE"
  printf 'Next steps:\n'
  printf '  source "%s"\n' "$ENV_FILE"
  printf '  ./onboard-nemoclaw.sh\n'
}

main "$@"