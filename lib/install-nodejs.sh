#!/usr/bin/env bash
set -Eeuo pipefail

NODE_MAJOR="${NODE_MAJOR:-22}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

usage() {
  cat <<EOF_USAGE
Usage:
  ./install-nodejs.sh

Environment:
  NODE_MAJOR   Node.js major line to install from NodeSource (default: 22)
EOF_USAGE
}

already_installed() {
  command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1
}

show_versions() {
  printf 'node: %s\n' "$(node --version)"
  printf 'npm:  %s\n' "$(npm --version)"
}

install_nodesource_node() {
  need_cmd sudo
  need_cmd curl
  need_cmd apt-get

  log "Configuring NodeSource repository for Node.js ${NODE_MAJOR}.x"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo bash -

  log "Installing nodejs"
  sudo apt-get install -y nodejs
}

main() {
  case "${1:-}" in
    -h|--help)
      usage
      exit 0
      ;;
  esac

  if already_installed; then
    log "Node.js and npm already installed"
    show_versions
    exit 0
  fi

  install_nodesource_node

  already_installed || die "Node.js installation completed but node/npm were not found in PATH."

  log "Installed Node.js"
  show_versions
}

main "$@"
