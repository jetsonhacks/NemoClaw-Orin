#!/usr/bin/env bash
set -Eeuo pipefail

# LEGACY: retained for older JetsonHacks install references. New NemoClaw
# installs should use upstream NVIDIA/NemoClaw.
#
# Prepare a Jetson Orin host for OpenShell/NemoClaw by:
# - installing or verifying the required host-side tools
# - running the reusable host-prereqs helper
# - verifying Docker / bridge netfilter / host iptables state
# - selecting the OpenShell cluster version to use
# - writing an environment file that exports OPENSHELL_CLUSTER_IMAGE
#
# Tool installation is delegated to standalone scripts:
#   install-nodejs.sh         — Node.js and npm
#   install-openshell-cli.sh  — OpenShell CLI
#   install-nemoclaw-cli.sh   — NemoClaw CLI (git clone + npm link)
#
# This script does NOT run `openshell gateway start` or `nemoclaw onboard`.
# Keep the heavier onboarding phase separate so failures are easier to debug.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPONENT_VERSIONS_PATH="${COMPONENT_VERSIONS_PATH:-$SCRIPT_DIR/lib/component-versions.sh}"
[[ -f "$COMPONENT_VERSIONS_PATH" ]] || {
  printf '\n[ERROR] Missing component versions file: %s\n' "$COMPONENT_VERSIONS_PATH" >&2
  exit 1
}
# shellcheck disable=SC1090
source "$COMPONENT_VERSIONS_PATH"

INSTALL_NODEJS_SCRIPT="${INSTALL_NODEJS_SCRIPT:-$SCRIPT_DIR/lib/bootstrap/install-nodejs.sh}"
INSTALL_OPENSHELL_SCRIPT="${INSTALL_OPENSHELL_SCRIPT:-$SCRIPT_DIR/lib/bootstrap/install-openshell-cli.sh}"
INSTALL_NEMOCLAW_SCRIPT="${INSTALL_NEMOCLAW_SCRIPT:-$SCRIPT_DIR/lib/bootstrap/install-nemoclaw-cli.sh}"
UPDATE_CHECKER_PATH="${UPDATE_CHECKER_PATH:-$SCRIPT_DIR/lib/check-openshell-cluster-update.sh}"
HOST_PREREQS_SCRIPT="${HOST_PREREQS_SCRIPT:-$SCRIPT_DIR/lib/bootstrap/setup-openshell-host-prereqs.sh}"
OPENSHELL_CLUSTER_IMAGE_REPO="${OPENSHELL_CLUSTER_IMAGE_REPO:-ghcr.io/nvidia/openshell/cluster}"
ENV_FILE="${ENV_FILE:-$HOME/.config/openshell/jetson-orin.env}"
DEFAULT_CLUSTER_VERSION="${DEFAULT_CLUSTER_VERSION:-$OPEN_SHELL_VERSION_PIN}"
DISCOVER_LATEST_CLUSTER_VERSION="${DISCOVER_LATEST_CLUSTER_VERSION:-false}"
NODE_MAJOR="${NODE_MAJOR:-22}"
OPENSHELL_INSTALL_URL="${OPENSHELL_INSTALL_URL:-https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh}"
OPENSHELL_VERSION="${OPENSHELL_VERSION:-$OPEN_SHELL_CLI_VERSION_PIN}"
NEMOCLAW_CLONE_URL="${NEMOCLAW_CLONE_URL:-$NEMOCLAW_REPO_URL}"
OPENSHELL_CLUSTER_VERSION=""
OPENSHELL_CLUSTER_IMAGE=""

log()      { printf '\n==> %s\n' "$*"; }
warn()     { printf '\n[WARN] %s\n' "$*" >&2; }
die()      { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

usage() {
  cat <<'EOF_USAGE'
Usage:
  ./setup-jetson-orin.sh

Environment overrides:
  INSTALL_NODEJS_SCRIPT=/path         Override path to install-nodejs.sh
  INSTALL_OPENSHELL_SCRIPT=/path      Override path to install-openshell-cli.sh
  INSTALL_NEMOCLAW_SCRIPT=/path       Override path to install-nemoclaw-cli.sh
  HOST_PREREQS_SCRIPT=/path           Override path to host-prereqs helper
  COMPONENT_VERSIONS_PATH=/path       Override path to component-versions.sh
  OPENSHELL_CLUSTER_IMAGE_REPO=repo   Override the upstream OpenShell cluster image repository
  DEFAULT_CLUSTER_VERSION=x.y.z       Pinned cluster version to use (default: ${DEFAULT_CLUSTER_VERSION})
  DISCOVER_LATEST_CLUSTER_VERSION=false
                                     When true, query GitHub releases and override DEFAULT_CLUSTER_VERSION
  NODE_MAJOR=22                       Node.js major line (passed to install-nodejs.sh)
  OPENSHELL_INSTALL_URL=https://...   OpenShell install script URL (passed to install-openshell-cli.sh)
  OPENSHELL_VERSION=v0.0.20           OpenShell version (passed to install-openshell-cli.sh)
  NEMOCLAW_CLONE_URL=https://...      NemoClaw git repository URL (passed to install-nemoclaw-cli.sh)
  NEMOCLAW_GIT_REF=<ref>|latest       NemoClaw git ref (passed to install-nemoclaw-cli.sh)
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

install_tools() {
  [[ -f "$INSTALL_NODEJS_SCRIPT" ]] \
    || die "install-nodejs.sh not found: $INSTALL_NODEJS_SCRIPT"
  [[ -f "$INSTALL_OPENSHELL_SCRIPT" ]] \
    || die "install-openshell-cli.sh not found: $INSTALL_OPENSHELL_SCRIPT"
  [[ -f "$INSTALL_NEMOCLAW_SCRIPT" ]] \
    || die "install-nemoclaw-cli.sh not found: $INSTALL_NEMOCLAW_SCRIPT"

  NODE_MAJOR="$NODE_MAJOR" \
    bash "$INSTALL_NODEJS_SCRIPT"

  OPENSHELL_INSTALL_URL="$OPENSHELL_INSTALL_URL" \
  OPENSHELL_VERSION="$OPENSHELL_VERSION" \
    bash "$INSTALL_OPENSHELL_SCRIPT"
  # Pick up ~/.local/bin in this shell after the subshell install
  ensure_local_bin_on_path

  NEMOCLAW_CLONE_URL="$NEMOCLAW_CLONE_URL" \
  NEMOCLAW_GIT_REF="$NEMOCLAW_GIT_REF" \
    bash "$INSTALL_NEMOCLAW_SCRIPT"
  # Pick up npm bin and ~/.local/bin in this shell after the subshell install
  ensure_npm_bin_on_path
  ensure_local_bin_on_path
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
}

discover_cluster_version() {
  if [[ "$DISCOVER_LATEST_CLUSTER_VERSION" == "true" && -x "$UPDATE_CHECKER_PATH" ]]; then
    log "Discovering latest OpenShell cluster version"
    OPENSHELL_CLUSTER_VERSION="$($UPDATE_CHECKER_PATH --latest-version)" || \
      die "Failed to determine latest OpenShell cluster version via $UPDATE_CHECKER_PATH"
  elif [[ "$DISCOVER_LATEST_CLUSTER_VERSION" == "true" ]]; then
    warn "Update checker not executable: $UPDATE_CHECKER_PATH"
    warn "Falling back to DEFAULT_CLUSTER_VERSION=$DEFAULT_CLUSTER_VERSION"
    OPENSHELL_CLUSTER_VERSION="$DEFAULT_CLUSTER_VERSION"
  else
    log "Using pinned OpenShell cluster version"
    OPENSHELL_CLUSTER_VERSION="$DEFAULT_CLUSTER_VERSION"
  fi

  [[ -n "$OPENSHELL_CLUSTER_VERSION" ]] || die "OpenShell cluster version is empty."
  OPENSHELL_CLUSTER_IMAGE="${OPENSHELL_CLUSTER_IMAGE_REPO}:${OPENSHELL_CLUSTER_VERSION}"

  printf 'Using upstream OpenShell cluster version: %s\n' "$OPENSHELL_CLUSTER_VERSION"
  printf 'Will use OpenShell cluster image: %s\n' "$OPENSHELL_CLUSTER_IMAGE"
}

verify_cluster_image() {
  log "Verifying OpenShell cluster image reference"
  docker image inspect "$OPENSHELL_CLUSTER_IMAGE" >/dev/null 2>&1 || \
    docker pull "$OPENSHELL_CLUSTER_IMAGE" >/dev/null
  docker run --rm --entrypoint sh "$OPENSHELL_CLUSTER_IMAGE" -lc 'iptables --version' || \
    die "Could not inspect iptables inside OpenShell cluster image: $OPENSHELL_CLUSTER_IMAGE"
}

write_env_file() {
  mkdir -p "$(dirname "$ENV_FILE")"

  log "Writing OpenShell environment file: $ENV_FILE"
  cat > "$ENV_FILE" <<EOF_ENV
export OPENSHELL_CLUSTER_IMAGE="$OPENSHELL_CLUSTER_IMAGE"
export OPENSHELL_CLUSTER_VERSION="$OPENSHELL_CLUSTER_VERSION"
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

  install_tools
  run_host_prereqs
  ensure_docker_running
  verify_host_state
  discover_cluster_version
  verify_cluster_image
  write_env_file

  log "Jetson Orin host setup complete"
  printf 'OpenShell cluster image: %s\n' "$OPENSHELL_CLUSTER_IMAGE"
  printf 'OpenShell env file:    %s\n' "$ENV_FILE"
  printf 'Next steps:\n'
  printf '  source ~/.bashrc\n'
  printf '  ./onboard-nemoclaw.sh\n'
}

main "$@"
