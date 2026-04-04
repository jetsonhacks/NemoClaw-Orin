#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPONENT_VERSIONS_PATH="${COMPONENT_VERSIONS_PATH:-$SCRIPT_DIR/../component-versions.sh}"
[[ -f "$COMPONENT_VERSIONS_PATH" ]] || {
  printf '\n[ERROR] Missing component versions file: %s\n' "$COMPONENT_VERSIONS_PATH" >&2
  exit 1
}
# shellcheck disable=SC1090
source "$COMPONENT_VERSIONS_PATH"

OPENSHELL_INSTALL_URL="${OPENSHELL_INSTALL_URL:-https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh}"
OPENSHELL_VERSION="${OPENSHELL_VERSION:-$OPEN_SHELL_CLI_VERSION_PIN}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

usage() {
  cat <<EOF_USAGE
Usage:
  ./lib/bootstrap/install-openshell-cli.sh

Environment:
  COMPONENT_VERSIONS_PATH Override path to component-versions.sh
  OPENSHELL_INSTALL_URL  Override the OpenShell install script URL
  OPENSHELL_VERSION      Override the OpenShell version to install (default: ${OPENSHELL_VERSION})
EOF_USAGE
}

ensure_local_bin_on_path() {
  local local_bin="$HOME/.local/bin"
  if [[ -d "$local_bin" && ":$PATH:" != *":$local_bin:"* ]]; then
    export PATH="$local_bin:$PATH"
  fi
}

install_openshell() {
  need_cmd curl
  need_cmd sh

  log "Installing OpenShell CLI ${OPENSHELL_VERSION}"
  curl -LsSf "$OPENSHELL_INSTALL_URL" | OPENSHELL_VERSION="$OPENSHELL_VERSION" sh
}

main() {
  case "${1:-}" in
    -h|--help)
      usage
      exit 0
      ;;
  esac

  ensure_local_bin_on_path

  if command -v openshell >/dev/null 2>&1; then
    log "OpenShell CLI already installed"
    openshell --version
    exit 0
  fi

  install_openshell

  ensure_local_bin_on_path
  command -v openshell >/dev/null 2>&1 || die "OpenShell installed but 'openshell' is not in PATH. Open a new shell or start a new shell session and try again."

  log "Installed OpenShell CLI"
  openshell --version
}

main "$@"
