#!/usr/bin/env bash
set -Eeuo pipefail

# uninstall-nemoclaw-openshell.sh
#
# Goal:
#   Remove the NemoClaw/OpenShell user-level state that setup-jetson-orin.sh
#   and the related CLI installers add.
#
# Removes:
#   - OpenShell/NemoClaw gateway state, containers, volumes, and related images
#   - NemoClaw npm link state and the ~/NemoClaw clone
#   - OpenShell/NemoClaw/OpenClaw config, cache, and local data directories
#   - setup-added ~/.bashrc lines
#   - ~/.config/openshell/jetson-orin.env
#
# Notes:
#   - This is intentionally destructive.
#   - It does NOT uninstall Docker Engine or Node.js itself.
#   - It is safe to run multiple times.

BASHRC="${BASHRC:-$HOME/.bashrc}"
NEMOCLAW_CLONE_DIR="${NEMOCLAW_CLONE_DIR:-$HOME/NemoClaw}"
ENV_FILE="${ENV_FILE:-$HOME/.config/openshell/jetson-orin.env}"

ASSUME_YES=false

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
pass() { printf '  ✓  %s\n' "$*"; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF_USAGE'
Usage:
  ./lib/maintenance/uninstall-nemoclaw-openshell.sh [options]

Options:
  --yes       Skip interactive confirmation prompt
  -h, --help  Show this help
EOF_USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) ASSUME_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

remove_path_if_exists() {
  local path="$1"
  if [[ -e "$path" || -L "$path" ]]; then
    rm -rf "$path"
    pass "Removed $path"
  fi
}

remove_line_from_file() {
  local line="$1"
  local file="$2"

  [[ -f "$file" ]] || return 0

  if grep -Fqx "$line" "$file"; then
    local tmp
    tmp="$(mktemp)"
    grep -Fvx "$line" "$file" > "$tmp" || true
    mv "$tmp" "$file"
    pass "Removed exact line from $file"
  fi
}

remove_matching_lines_from_file() {
  local pattern="$1"
  local file="$2"

  [[ -f "$file" ]] || return 0

  if grep -Eq "$pattern" "$file"; then
    local tmp
    tmp="$(mktemp)"
    grep -Ev "$pattern" "$file" > "$tmp" || true
    mv "$tmp" "$file"
    pass "Removed matching lines from $file"
  fi
}

confirm_destructive() {
  echo ""
  echo "FULL UNINSTALL: NemoClaw + OpenShell"
  echo ""
  echo "This will remove ALL local NemoClaw/OpenShell data and setup state,"
  echo "including:"
  echo "  - OpenShell/NemoClaw Docker containers, volumes, and local images"
  echo "  - CLI binaries and npm link state"
  echo "  - $NEMOCLAW_CLONE_DIR"
  echo "  - hidden config/state/cache directories"
  echo "  - $ENV_FILE and related shell wiring"
  echo ""
  echo "This action is destructive and not reversible."
  echo ""

  if [[ "$ASSUME_YES" == "true" ]]; then
    return 0
  fi

  read -r -p "Type FULL_UNINSTALL to continue: " confirm
  [[ "$confirm" == "FULL_UNINSTALL" ]] || {
    echo ""
    echo "Cancelled. Nothing changed."
    echo ""
    exit 0
  }
}

stop_openshell_best_effort() {
  log "Stopping/removing OpenShell gateways (best effort)"
  if command -v openshell >/dev/null 2>&1; then
    openshell forward stop 18789 2>/dev/null || true
    openshell gateway stop -g nemoclaw 2>/dev/null || true
    openshell gateway stop -g openshell 2>/dev/null || true
    openshell gateway destroy -g nemoclaw 2>/dev/null || true
    openshell gateway destroy -g openshell 2>/dev/null || true
    pass "OpenShell gateway cleanup attempted"
  else
    warn "openshell CLI not found; skipping CLI-driven gateway cleanup"
  fi
}

remove_docker_artifacts() {
  log "Removing Docker artifacts (best effort)"
  if ! command -v docker >/dev/null 2>&1; then
    warn "docker not found; skipping Docker artifact cleanup"
    return 0
  fi

  while IFS= read -r container_name; do
    [[ -n "$container_name" ]] || continue
    docker rm -f "$container_name" >/dev/null 2>&1 || true
    pass "Removed container: $container_name"
  done < <(docker ps -a --format '{{.Names}}' | grep -E '^openshell-cluster-|^openshell-|^nemoclaw' || true)

  while IFS= read -r volume_name; do
    [[ -n "$volume_name" ]] || continue
    docker volume rm -f "$volume_name" >/dev/null 2>&1 || true
    pass "Removed volume: $volume_name"
  done < <(docker volume ls --format '{{.Name}}' | grep -E '^openshell-cluster-|^openshell|^nemoclaw' || true)

  while IFS= read -r image_name; do
    [[ -n "$image_name" ]] || continue
    docker image rm -f "$image_name" >/dev/null 2>&1 || true
    pass "Removed image: $image_name"
  done < <(
    docker image ls --format '{{.Repository}}:{{.Tag}}' | \
      grep -E '^(openshell-cluster:(patched-|jetson-legacy-).+|ghcr\.io/nvidia/openshell/cluster:.+|openshell/sandbox-from:.+|ghcr\.io/nvidia/nemoclaw/sandbox-base:.+|ghcr\.io/nvidia/nemoclaw/.+)$' || true
  )
}

remove_npm_links_and_clone() {
  log "Removing NemoClaw npm link and clone"

  if [[ -d "$NEMOCLAW_CLONE_DIR" ]] && command -v npm >/dev/null 2>&1; then
    (
      cd "$NEMOCLAW_CLONE_DIR"
      npm unlink --ignore-scripts >/dev/null 2>&1 || true
    )
    pass "npm unlink attempted in $NEMOCLAW_CLONE_DIR"
  fi

  local npm_prefix=""
  if command -v npm >/dev/null 2>&1; then
    npm_prefix="$(npm config get prefix 2>/dev/null || true)"
  fi
  [[ -z "$npm_prefix" || "$npm_prefix" == "undefined" ]] && npm_prefix="$HOME/.local"

  remove_path_if_exists "$NEMOCLAW_CLONE_DIR"
  remove_path_if_exists "$npm_prefix/bin/nemoclaw"
  remove_path_if_exists "$npm_prefix/bin/openclaw"
  remove_path_if_exists "$npm_prefix/bin/openshell"
  remove_path_if_exists "$npm_prefix/lib/node_modules/nemoclaw"
  remove_path_if_exists "$npm_prefix/lib/node_modules/openshell"
  remove_path_if_exists "$HOME/.local/bin/nemoclaw"
  remove_path_if_exists "$HOME/.local/bin/openclaw"
  remove_path_if_exists "$HOME/.local/bin/openshell"
}

remove_user_state() {
  log "Removing hidden config/state directories"

  local state_dirs=(
    "$HOME/.config/openshell"
    "$HOME/.openshell"
    "$HOME/.cache/openshell"
    "$HOME/.local/share/openshell"
    "$HOME/.config/nemoclaw"
    "$HOME/.nemoclaw"
    "$HOME/.cache/nemoclaw"
    "$HOME/.local/share/nemoclaw"
    "$HOME/.config/openclaw"
    "$HOME/.openclaw"
    "$HOME/.cache/openclaw"
    "$HOME/.local/share/openclaw"
  )

  local dir
  for dir in "${state_dirs[@]}"; do
    remove_path_if_exists "$dir"
  done
}

clean_shell_setup() {
  log "Cleaning shell setup lines"

  if [[ ! -f "$BASHRC" ]]; then
    warn "$BASHRC not found; skipping shell cleanup"
    return 0
  fi

  cp "$BASHRC" "${BASHRC}.uninstall-nemoclaw-openshell.bak"
  pass "Backed up $BASHRC to ${BASHRC}.uninstall-nemoclaw-openshell.bak"

  remove_line_from_file "source \"$ENV_FILE\"" "$BASHRC"
  remove_line_from_file 'export PATH="$HOME/.local/bin:$PATH"' "$BASHRC"
  remove_matching_lines_from_file 'OPENSHELL_CLUSTER_IMAGE|jetson-orin\.env' "$BASHRC"
}

verify_removal() {
  log "Verification"

  if command -v openshell >/dev/null 2>&1; then
    warn "'openshell' is still in PATH in this shell: $(command -v openshell)"
  else
    pass "openshell not found in PATH"
  fi

  if command -v nemoclaw >/dev/null 2>&1; then
    warn "'nemoclaw' is still in PATH in this shell: $(command -v nemoclaw)"
  else
    pass "nemoclaw not found in PATH"
  fi

  if command -v openclaw >/dev/null 2>&1; then
    warn "'openclaw' is still in PATH in this shell: $(command -v openclaw)"
  else
    pass "openclaw not found in PATH"
  fi
}

main() {
  confirm_destructive
  stop_openshell_best_effort
  remove_docker_artifacts
  remove_npm_links_and_clone
  remove_user_state
  clean_shell_setup
  verify_removal

  echo ""
  echo "Full uninstall complete."
  echo "Open a new terminal to clear stale PATH entries in the current shell."
  echo ""
}

main "$@"
