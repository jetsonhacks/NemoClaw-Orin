#!/usr/bin/env bash
set -Eeuo pipefail

NODE_MAJOR="${NODE_MAJOR:-22}"
MIN_NODE_VERSION="${MIN_NODE_VERSION:-22.16.0}"

log()      { printf '\n==> %s\n' "$*"; }
warn()     { printf '\n[WARN] %s\n' "$*" >&2; }
die()      { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

usage() {
  cat <<'EOF_USAGE'
Usage:
  ./lib/bootstrap/install-nodejs.sh

Environment overrides:
  NODE_MAJOR=22              Node.js major line to install from NodeSource
  MIN_NODE_VERSION=22.16.0   Minimum acceptable Node.js version
EOF_USAGE
}

strip_v() {
  local v="${1:-}"
  printf '%s\n' "${v#v}"
}

version_ge() {
  local lhs rhs
  lhs="$(strip_v "${1:-0}")"
  rhs="$(strip_v "${2:-0}")"
  dpkg --compare-versions "$lhs" ge "$rhs"
}

resolved_node() {
  command -v node 2>/dev/null || true
}

resolved_npm() {
  command -v npm 2>/dev/null || true
}

show_path_diagnostics() {
  printf 'Resolved node: %s\n' "$(resolved_node)"
  printf 'Resolved npm:  %s\n' "$(resolved_npm)"
  printf 'All node binaries in PATH:\n'
  which -a node 2>/dev/null || true
  printf 'All npm binaries in PATH:\n'
  which -a npm 2>/dev/null || true
}

show_versions() {
  printf 'node: %s\n' "$(node --version 2>/dev/null || echo 'not found')"
  printf 'npm:  %s\n' "$(npm --version 2>/dev/null || echo 'not found')"
}

show_system_versions() {
  printf '/usr/bin/node: %s\n' "$(/usr/bin/node --version 2>/dev/null || echo 'not found')"
  printf '/usr/bin/npm:  %s\n' "$(/usr/bin/npm --version 2>/dev/null || echo 'not found')"
}

have_node_and_npm() {
  [[ -n "$(resolved_node)" && -n "$(resolved_npm)" ]]
}

current_node_meets_minimum() {
  have_node_and_npm || return 1
  version_ge "$(node --version 2>/dev/null || echo 0)" "$MIN_NODE_VERSION"
}

system_node_exists() {
  [[ -x /usr/bin/node ]]
}

system_node_meets_minimum() {
  system_node_exists || return 1
  version_ge "$(/usr/bin/node --version 2>/dev/null || echo 0)" "$MIN_NODE_VERSION"
}

install_or_upgrade_node() {
  need_cmd sudo
  need_cmd curl
  need_cmd apt-get
  need_cmd dpkg

  log "Configuring NodeSource repository for Node.js ${NODE_MAJOR}.x"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo bash -

  log "Installing/upgrading nodejs"
  sudo apt-get install -y nodejs
}

clear_shell_command_cache() {
  hash -r 2>/dev/null || true
}

warn_if_shadowed() {
  local current_node current_npm
  current_node="$(resolved_node)"
  current_npm="$(resolved_npm)"

  if [[ -n "$current_node" && "$current_node" != "/usr/bin/node" ]]; then
    warn "PATH resolves node to '$current_node' instead of '/usr/bin/node'."
    warn "A different Node.js installation is shadowing the system Node.js."
  fi

  if [[ -n "$current_npm" && "$current_npm" != "/usr/bin/npm" ]]; then
    warn "PATH resolves npm to '$current_npm' instead of '/usr/bin/npm'."
    warn "A different npm installation is shadowing the system npm."
  fi
}

print_shadowing_help() {
  cat <<'EOF_HELP' >&2

A different Node.js installation appears to be earlier on PATH than /usr/bin/node.

Common causes:
  - /usr/local/bin/node
  - nvm-managed Node.js
  - an old manually installed Node.js

Useful checks:
  command -v node
  which -a node
  ls -l "$(command -v node)"
  /usr/bin/node --version
  node --version

If you want to use the system Node.js from NodeSource in the current shell, try:
  export PATH=/usr/bin:$PATH
  hash -r

If you use nvm, you may need to disable it for this session or select a newer Node.js.
EOF_HELP
}

main() {
  case "${1:-}" in
    -h|--help)
      usage
      exit 0
      ;;
  esac

  need_cmd dpkg

  if current_node_meets_minimum; then
    log "Node.js and npm already installed and meet minimum version"
    show_versions
    exit 0
  fi

  if have_node_and_npm; then
    warn "Installed Node.js is too old for NemoClaw"
    printf 'Required minimum: v%s\n' "$MIN_NODE_VERSION"
    show_versions
  else
    warn "Node.js and/or npm not found"
    show_path_diagnostics
  fi

  install_or_upgrade_node
  clear_shell_command_cache

  log "Post-install diagnostics"
  show_path_diagnostics
  show_versions
  show_system_versions

  system_node_exists || die "/usr/bin/node was not found after installation."

  if ! system_node_meets_minimum; then
    die "Installed system Node.js is still below required minimum v${MIN_NODE_VERSION}."
  fi

  warn_if_shadowed

  if current_node_meets_minimum; then
    log "Active Node.js now meets minimum version"
    show_versions
    exit 0
  fi

  warn "The system Node.js was upgraded successfully, but the active 'node' command in PATH is still older."
  print_shadowing_help
  exit 1
}

main "$@"
