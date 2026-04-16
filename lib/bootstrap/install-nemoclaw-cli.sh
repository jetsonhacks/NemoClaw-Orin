#!/usr/bin/env bash
set -Eeuo pipefail

# install-nemoclaw-cli.sh — Install the NemoClaw CLI on a Jetson host
#
# Clones the NemoClaw repository to ~/NemoClaw, applies the Jetson-specific
# patch that makes nemoclaw onboard respect a pre-set OPENSHELL_CLUSTER_IMAGE,
# then links the CLI into the npm global bin directory.
#
# The clone directory must remain in place after installation — nemoclaw onboard
# stages its Docker build context from it at runtime and requires the full
# source tree.
#
# Safe to run multiple times — skips the install if nemoclaw is already on PATH.
#
# Usage:
#   ./lib/bootstrap/install-nemoclaw-cli.sh
#
# Optional environment overrides:
#   NEMOCLAW_CLONE_URL=https://...   Override the NemoClaw git repository URL
#   NEMOCLAW_GIT_REF=<ref>|latest    Override the NemoClaw git ref selection

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPONENT_VERSIONS_PATH="${COMPONENT_VERSIONS_PATH:-$SCRIPT_DIR/../component-versions.sh}"
[[ -f "$COMPONENT_VERSIONS_PATH" ]] || {
  printf '\n[ERROR] Missing component versions file: %s\n' "$COMPONENT_VERSIONS_PATH" >&2
  exit 1
}
# shellcheck disable=SC1090
source "$COMPONENT_VERSIONS_PATH"

NEMOCLAW_CLONE_URL="${NEMOCLAW_CLONE_URL:-$NEMOCLAW_REPO_URL}"
NEMOCLAW_GIT_REF="${NEMOCLAW_GIT_REF:-latest}"

log()      { printf '\n==> %s\n' "$*"; }
warn()     { printf '\n[WARN] %s\n' "$*" >&2; }
die()      { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

usage() {
  cat <<EOF_USAGE
Usage:
  ./lib/bootstrap/install-nemoclaw-cli.sh

Environment:
  COMPONENT_VERSIONS_PATH Override path to component-versions.sh
  NEMOCLAW_CLONE_URL   Override the NemoClaw git repository URL
                       (default: ${NEMOCLAW_CLONE_URL})
  NEMOCLAW_GIT_REF    Override the NemoClaw git ref
                      (default: ${NEMOCLAW_GIT_REF})
EOF_USAGE
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

ensure_line_in_file() {
  local line="$1"
  local file="$2"
  touch "$file"
  grep -Fqx "$line" "$file" || printf '%s\n' "$line" >> "$file"
}

redirect_npm_prefix_if_system() {
  # When Node.js is installed system-wide (e.g. via NodeSource apt package),
  # npm's default global prefix is a root-owned path such as /usr or
  # /usr/lib/node_modules.  npm link would then require sudo and fail with
  # EACCES.  Detect that case and redirect to ~/.local before doing anything
  # else so the link target is user-writable.
  local current_prefix
  current_prefix="$(npm config get prefix 2>/dev/null || true)"
  if [[ -z "$current_prefix" || "$current_prefix" == "undefined" \
        || "$current_prefix" == /usr || "$current_prefix" == /usr/* \
        || "$current_prefix" == /opt/* ]]; then
    warn "npm global prefix is a system path (${current_prefix:-unset}) — redirecting to $HOME/.local to avoid needing sudo"
    npm config set prefix "$HOME/.local"
    mkdir -p "$HOME/.local/bin"
  fi
}

checkout_nemoclaw_ref() {
  local clone_dir="$1"
  local default_branch

  if [[ "$NEMOCLAW_GIT_REF" == "latest" ]]; then
    log "Using NemoClaw default branch HEAD"
    git -C "$clone_dir" fetch --prune origin
    default_branch="$(git -C "$clone_dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
    [[ -n "$default_branch" ]] || default_branch="main"
    git -C "$clone_dir" checkout "$default_branch" 2>/dev/null || git -C "$clone_dir" checkout -b "$default_branch" --track "origin/$default_branch"
    git -C "$clone_dir" pull --ff-only origin "$default_branch"
    return 0
  fi

  log "Checking out NemoClaw ref: $NEMOCLAW_GIT_REF"
  git -C "$clone_dir" fetch --prune origin
  git -C "$clone_dir" checkout --detach "$NEMOCLAW_GIT_REF"
}

patch_nemoclaw_onboard() {
  # NemoClaw unconditionally overwrites OPENSHELL_CLUSTER_IMAGE with
  # the upstream ghcr.io image, ignoring any value already set in the
  # environment. On Jetson we need the patched local image selected by this
  # repository rather than the upstream default image. This patch makes
  # NemoClaw respect a pre-set OPENSHELL_CLUSTER_IMAGE.
  #
  # The patch is idempotent: it checks for the already-patched string before
  # applying, so re-running is safe.

  local clone_dir="$1"
  local target="$clone_dir/bin/lib/agent-onboard.js"

  [[ -f "$target" ]] || die "Cannot patch NemoClaw onboard: file not found: $target"

  local image_needle='if (stableGatewayImage && openshellVersion) {'
  local image_patch='if (stableGatewayImage && openshellVersion && !process.env.OPENSHELL_CLUSTER_IMAGE) {'
  local changed="false"

  if grep -qF "$image_patch" "$target"; then
    log "NemoClaw image override patch already applied - skipping"
  elif grep -qF "$image_needle" "$target"; then
    log "Patching NemoClaw onboard to respect OPENSHELL_CLUSTER_IMAGE"
    local image_patch_escaped="${image_patch//&/\\&}"
    sed -i "s|${image_needle}|${image_patch_escaped}|" "$target"
    grep -qF "$image_patch" "$target" || die "Image override patch verification failed - check $target manually"
    changed="true"
  else
    warn "NemoClaw image override patch: expected string not found in $target"
    warn "Review manually: add '&& !process.env.OPENSHELL_CLUSTER_IMAGE' to the stableGatewayImage condition."
  fi

  if [[ "$changed" == "true" ]]; then
    printf 'Patched: %s\n' "$target"
  fi
}

install_nemoclaw() {
  need_cmd git
  need_cmd npm

  local clone_dir="$HOME/NemoClaw"

  log "Installing NemoClaw CLI"
  printf 'Clone target: %s\n' "$clone_dir"
  printf 'Repository:   %s\n' "$NEMOCLAW_CLONE_URL"
  printf 'Git ref:      %s\n' "$NEMOCLAW_GIT_REF"

  # Redirect npm global prefix away from system paths before cloning so that
  # npm link writes to a user-writable location.
  redirect_npm_prefix_if_system

  if [[ -d "$clone_dir" ]]; then
    warn "Clone directory already exists: $clone_dir"
    warn "Refreshing existing clone instead of cloning fresh"
    # The Jetson patch modifies bin/lib/agent-onboard.js. Reset it before pulling so
    # upstream changes to that file are not blocked by the local modification.
    # The patch is re-applied unconditionally below.
    git -C "$clone_dir" checkout -- bin/lib/agent-onboard.js 2>/dev/null || true
  else
    git clone "$NEMOCLAW_CLONE_URL" "$clone_dir"
  fi

  checkout_nemoclaw_ref "$clone_dir"
  patch_nemoclaw_onboard "$clone_dir"

  (
    cd "$clone_dir"
    npm install --ignore-scripts
    npm link --ignore-scripts
  )

  ensure_npm_bin_on_path
  ensure_local_bin_on_path

  command -v nemoclaw >/dev/null 2>&1 || \
    die "NemoClaw installed but 'nemoclaw' not found in PATH. Check: npm config get prefix"

  local npm_bin
  npm_bin="$(npm config get prefix)/bin"
  ensure_line_in_file "export PATH=\"$npm_bin:\$PATH\"" "$HOME/.bashrc"
  ensure_line_in_file 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.bashrc"

  hash -r 2>/dev/null || true
}

main() {
  case "${1:-}" in
    -h|--help)
      usage
      exit 0
      ;;
  esac

  ensure_local_bin_on_path

  if command -v nemoclaw >/dev/null 2>&1; then
    log "NemoClaw CLI already installed"
    printf 'nemoclaw: %s\n' "$(command -v nemoclaw)"
    exit 0
  fi

  install_nemoclaw

  log "Installed NemoClaw CLI"
  printf 'nemoclaw: %s\n' "$(command -v nemoclaw)"
}

main "$@"
