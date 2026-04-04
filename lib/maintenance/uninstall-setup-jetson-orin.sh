#!/usr/bin/env bash
set -Eeuo pipefail

# uninstall-setup-jetson-orin.sh
#
# Goal:
#   Return the machine to a state where setup-jetson-orin.sh behaves like a
#   fresh install.
#
# Removes:
#   - NemoClaw/OpenShell state, containers, images, config, caches
#   - npm-linked CLI binaries and user-global node_modules
#   - Node.js and npm apt packages
#   - NodeSource apt repo files (if present)
#   - setup-added ~/.bashrc lines
#   - ~/.npmrc prefix override if it points to ~/.local
#   - ~/.config/openshell/jetson-orin.env
#
# Optional:
#   --yes                  Skip confirmation prompt
#   --keep-docker          Do not remove Docker artifacts
#   --keep-clone           Do not remove ~/NemoClaw
#   --keep-node            Do not remove nodejs/npm apt packages
#   --dry-run              Print actions without changing anything
#
# Notes:
#   - This is intentionally destructive.
#   - It does NOT uninstall Docker Engine itself.
#   - It is safe to run multiple times.

BASHRC="${BASHRC:-$HOME/.bashrc}"
NEMOCLAW_CLONE_DIR="${NEMOCLAW_CLONE_DIR:-$HOME/NemoClaw}"
ENV_FILE="${ENV_FILE:-$HOME/.config/openshell/jetson-orin.env}"

ASSUME_YES=false
KEEP_DOCKER=false
KEEP_CLONE=false
KEEP_NODE=false
DRY_RUN=false

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
pass() { printf '  ✓  %s\n' "$*"; }
info() { printf '      %s\n' "$*"; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '[dry-run] '
    printf '%q ' "$@"
    printf '\n'
  else
    "$@"
  fi
}

usage() {
  cat <<'EOF_USAGE'
Usage:
  ./lib/maintenance/uninstall-setup-jetson-orin.sh [options]

Options:
  --yes          Skip interactive confirmation prompt
  --keep-docker  Keep Docker containers/volumes/images
  --keep-clone   Keep ~/NemoClaw clone directory
  --keep-node    Keep nodejs/npm installed
  --dry-run      Show planned actions only
  -h, --help     Show this help
EOF_USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) ASSUME_YES=true; shift ;;
    --keep-docker) KEEP_DOCKER=true; shift ;;
    --keep-clone) KEEP_CLONE=true; shift ;;
    --keep-node) KEEP_NODE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

remove_path_if_exists() {
  local p="$1"
  if [[ -e "$p" || -L "$p" ]]; then
    run rm -rf "$p"
    pass "Removed $p"
  fi
}

remove_line_from_file() {
  local line="$1"
  local file="$2"

  [[ -f "$file" ]] || return 0

  if grep -Fqx "$line" "$file"; then
    if [[ "$DRY_RUN" == "true" ]]; then
      printf '[dry-run] remove exact line from %s: %s\n' "$file" "$line"
    else
      local tmp
      tmp="$(mktemp)"
      grep -Fvx "$line" "$file" > "$tmp" || true
      mv "$tmp" "$file"
    fi
    pass "Removed exact line from $file"
  fi
}

remove_matching_lines_from_file() {
  local pattern="$1"
  local file="$2"

  [[ -f "$file" ]] || return 0

  if grep -Eq "$pattern" "$file"; then
    if [[ "$DRY_RUN" == "true" ]]; then
      printf '[dry-run] remove lines in %s matching regex: %s\n' "$file" "$pattern"
    else
      local tmp
      tmp="$(mktemp)"
      grep -Ev "$pattern" "$file" > "$tmp" || true
      mv "$tmp" "$file"
    fi
    pass "Removed matching lines from $file"
  fi
}

confirm_destructive() {
  echo ""
  echo "FULL RESET: setup-jetson-orin prerequisites"
  echo ""
  echo "This will remove local NemoClaw/OpenShell install state so that"
  echo "setup-jetson-orin.sh can run like a fresh install."
  echo ""
  echo "It will remove:"
  echo "  - NemoClaw/OpenShell state and shell wiring"
  echo "  - npm global links and user-global node modules"
  echo "  - nodejs/npm apt packages (unless --keep-node)"
  echo "  - Docker artifacts related to OpenShell/NemoClaw (unless --keep-docker)"
  echo "  - ~/NemoClaw clone (unless --keep-clone)"
  echo ""

  if [[ "$ASSUME_YES" == "true" ]]; then
    return 0
  fi

  read -r -p "Type FRESH_INSTALL_RESET to continue: " confirm
  [[ "$confirm" == "FRESH_INSTALL_RESET" ]] || {
    echo ""
    echo "Cancelled. Nothing changed."
    echo ""
    exit 0
  }
}

stop_openshell_best_effort() {
  log "Stopping/removing OpenShell gateways (best effort)"
  if command -v openshell >/dev/null 2>&1; then
    run openshell forward stop 18789
    run openshell gateway stop -g nemoclaw
    run openshell gateway stop -g openshell
    run openshell gateway destroy -g nemoclaw
    run openshell gateway destroy -g openshell
    pass "OpenShell gateway cleanup attempted"
  else
    warn "openshell CLI not found; skipping CLI-driven gateway cleanup"
  fi
}

remove_docker_artifacts() {
  [[ "$KEEP_DOCKER" == "true" ]] && {
    warn "Keeping Docker artifacts (--keep-docker)"
    return 0
  }

  log "Removing Docker artifacts (best effort)"
  if ! command -v docker >/dev/null 2>&1; then
    warn "docker not found; skipping Docker cleanup"
    return 0
  fi

  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    run docker rm -f "$c"
    pass "Removed container: $c"
  done < <(docker ps -a --format '{{.Names}}' | grep -E '^openshell-cluster-|^openshell-|^nemoclaw' || true)

  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    run docker volume rm -f "$v"
    pass "Removed volume: $v"
  done < <(docker volume ls --format '{{.Name}}' | grep -E '^openshell-cluster-|^openshell|^nemoclaw' || true)

  while IFS= read -r img; do
    [[ -n "$img" ]] || continue
    run docker image rm -f "$img"
    pass "Removed image: $img"
  done < <(
    docker image ls --format '{{.Repository}}:{{.Tag}}' | \
      grep -E '^(openshell-cluster:(patched-|jetson-legacy-).+|ghcr\.io/nvidia/openshell/cluster:.+|openshell/sandbox-from:.+|ghcr\.io/nvidia/nemoclaw/sandbox-base:.+)$' || true
  )
}

remove_npm_links_and_prefix_state() {
  log "Removing npm link/user prefix state"

  local npm_prefix=""
  if command -v npm >/dev/null 2>&1; then
    npm_prefix="$(npm config get prefix 2>/dev/null || true)"
  fi
  [[ -z "$npm_prefix" || "$npm_prefix" == "undefined" ]] && npm_prefix="$HOME/.local"

  if [[ -d "$NEMOCLAW_CLONE_DIR" && "$KEEP_CLONE" != "true" && -x "$(command -v npm || true)" ]]; then
    local package_name=""
    if [[ -f "$NEMOCLAW_CLONE_DIR/package.json" ]]; then
      package_name="$(python3 - "$NEMOCLAW_CLONE_DIR/package.json" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("")
    raise SystemExit(0)

print(data.get("name", ""))
PY
)"
    fi

    if [[ -n "$package_name" ]]; then
      run npm unlink --global --ignore-scripts "$package_name" || true
      pass "npm unlink attempted for package: $package_name"
    else
      warn "Could not determine package name from $NEMOCLAW_CLONE_DIR/package.json; skipping npm unlink"
    fi
  fi

  remove_path_if_exists "$npm_prefix/bin/nemoclaw"
  remove_path_if_exists "$npm_prefix/bin/openclaw"
  remove_path_if_exists "$npm_prefix/bin/openshell"
  remove_path_if_exists "$npm_prefix/bin/npm"
  remove_path_if_exists "$npm_prefix/bin/npx"

  remove_path_if_exists "$npm_prefix/lib/node_modules/nemoclaw"
  remove_path_if_exists "$npm_prefix/lib/node_modules/openshell"
  remove_path_if_exists "$npm_prefix/lib/node_modules"

  remove_path_if_exists "$HOME/.local/bin/nemoclaw"
  remove_path_if_exists "$HOME/.local/bin/openclaw"
  remove_path_if_exists "$HOME/.local/bin/openshell"
}

remove_clone_and_user_state() {
  log "Removing NemoClaw clone and hidden config/state directories"

  if [[ "$KEEP_CLONE" != "true" ]]; then
    remove_path_if_exists "$NEMOCLAW_CLONE_DIR"
  else
    warn "Keeping clone directory (--keep-clone): $NEMOCLAW_CLONE_DIR"
  fi

  for d in \
    "$HOME/.config/openshell" \
    "$HOME/.openshell" \
    "$HOME/.cache/openshell" \
    "$HOME/.local/share/openshell" \
    "$HOME/.config/nemoclaw" \
    "$HOME/.nemoclaw" \
    "$HOME/.cache/nemoclaw" \
    "$HOME/.local/share/nemoclaw" \
    "$HOME/.config/openclaw" \
    "$HOME/.openclaw" \
    "$HOME/.cache/openclaw" \
    "$HOME/.local/share/openclaw"; do
    remove_path_if_exists "$d"
  done
}

remove_setup_shell_wiring() {
  log "Cleaning shell setup lines"

  if [[ ! -f "$BASHRC" ]]; then
    warn "$BASHRC not found; skipping shell cleanup"
    return 0
  fi

  if [[ "$DRY_RUN" != "true" ]]; then
    cp "$BASHRC" "${BASHRC}.uninstall-setup-jetson-orin.bak"
    info "Backup saved: ${BASHRC}.uninstall-setup-jetson-orin.bak"
  fi

  remove_line_from_file 'export PATH="$HOME/.local/bin:$PATH"' "$BASHRC"
  remove_matching_lines_from_file '^export PATH="[^"]+/bin:\$PATH"$' "$BASHRC"
  remove_matching_lines_from_file 'jetson-orin\.env' "$BASHRC"
  remove_matching_lines_from_file 'OPENSHELL_CLUSTER_IMAGE' "$BASHRC"

  pass "Cleaned $BASHRC"
}

remove_env_and_npmrc() {
  log "Removing env file and npm user config"

  remove_path_if_exists "$ENV_FILE"

  local npmrc="$HOME/.npmrc"
  if [[ -f "$npmrc" ]]; then
    if grep -Eq '^[[:space:]]*prefix[[:space:]]*=[[:space:]]*/home/[^[:space:]]+/\.local[[:space:]]*$|^[[:space:]]*prefix[[:space:]]*=[[:space:]]*~/.local[[:space:]]*$' "$npmrc"; then
      remove_path_if_exists "$npmrc"
    else
      warn "Leaving $npmrc in place because it does not look like the setup-created ~/.local prefix override"
    fi
  fi
}

remove_node_packages_and_repo() {
  [[ "$KEEP_NODE" == "true" ]] && {
    warn "Keeping nodejs/npm installed (--keep-node)"
    return 0
  }

  log "Removing NodeSource apt repository files when present"
  local files=(
    /etc/apt/sources.list.d/nodesource.list
    /etc/apt/sources.list.d/nodesource.sources
    /etc/apt/sources.list.d/nodejs.list
    /usr/share/keyrings/nodesource.gpg
    /etc/apt/keyrings/nodesource.gpg
  )

  local found_any=false
  for f in "${files[@]}"; do
    if [[ -e "$f" ]]; then
      found_any=true
      run sudo rm -f "$f"
      pass "Removed $f"
    fi
  done

  log "Removing Node.js/npm apt packages"
  if command -v apt-get >/dev/null 2>&1; then
    run sudo apt-get remove -y nodejs npm || true
    run sudo apt-get purge -y nodejs npm || true
  else
    warn "apt-get not found; skipping package removal"
  fi

  if [[ "$found_any" == "true" ]]; then
    run sudo apt-get update || true
  fi
}

verification() {
  log "Verification"

  hash -r 2>/dev/null || true

  if command -v node >/dev/null 2>&1; then
    warn "'node' is still in PATH in this shell: $(command -v node)"
  else
    pass "node not found in PATH"
  fi

  if command -v npm >/dev/null 2>&1; then
    warn "'npm' is still in PATH in this shell: $(command -v npm)"
  else
    pass "npm not found in PATH"
  fi

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

  echo ""
  echo "Reset complete."
  echo "Open a new terminal, or run:"
  echo "  hash -r"
  echo "  source ~/.bashrc"
  echo ""
  echo "Then verify:"
  echo "  command -v node || true"
  echo "  command -v npm || true"
  echo "  command -v openshell || true"
  echo "  command -v nemoclaw || true"
  echo ""
  echo "Fresh reinstall:"
  echo "  ./setup-jetson-orin.sh"
  echo ""
}

main() {
  confirm_destructive
  stop_openshell_best_effort
  remove_docker_artifacts
  remove_npm_links_and_prefix_state
  remove_clone_and_user_state
  remove_setup_shell_wiring
  remove_env_and_npmrc
  remove_node_packages_and_repo
  verification
}

main "$@"
