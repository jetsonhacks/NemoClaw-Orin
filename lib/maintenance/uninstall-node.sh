#!/usr/bin/env bash
set -euo pipefail

# uninstall-node.sh — Remove Node.js and NemoClaw CLI
#
# Reverses what setup-jetson-orin.sh and install-nodejs.sh install:
#   - NemoClaw npm unlink and clone directory (~/NemoClaw)
#   - nemoclaw symlink in ~/.local/bin
#   - nodejs package installed via NodeSource apt
#   - NodeSource apt source list
#   - PATH lines added to ~/.bashrc by the setup scripts
#
# Does NOT remove:
#   - Docker Engine or NVIDIA container runtime
#   - OpenShell CLI or config
#   - Any other system packages
#
# Usage:
#   ./lib/maintenance/uninstall-node.sh

NEMOCLAW_CLONE_DIR="${NEMOCLAW_CLONE_DIR:-$HOME/NemoClaw}"
BASHRC="${BASHRC:-$HOME/.bashrc}"
NODESOURCE_LIST="/etc/apt/sources.list.d/nodesource.list"

log()  { printf '\n==> %s\n' "$*"; }
pass() { printf '  ✓  %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
info() { printf '      %s\n' "$*"; }

# ── Detect what is present ─────────────────────────────────────────────────────

node_installed=false
nodesource_present=false
clone_present=false
nemoclaw_symlink=""
npm_bin_nemoclaw=""
bashrc_has_node_lines=false

dpkg -s nodejs >/dev/null 2>&1 && node_installed=true
[[ -f "$NODESOURCE_LIST" ]] && nodesource_present=true
[[ -d "$NEMOCLAW_CLONE_DIR" ]] && clone_present=true

if [[ -L "$HOME/.local/bin/nemoclaw" ]]; then
    nemoclaw_symlink="$HOME/.local/bin/nemoclaw"
fi

if command -v npm >/dev/null 2>&1; then
    npm_prefix="$(npm config get prefix 2>/dev/null || true)"
    if [[ -n "$npm_prefix" && -x "$npm_prefix/bin/nemoclaw" ]]; then
        npm_bin_nemoclaw="$npm_prefix/bin/nemoclaw"
    fi
fi

if [[ -f "$BASHRC" ]] && grep -qE 'NemoClaw|nemoclaw|npm config get prefix|local/bin' "$BASHRC" 2>/dev/null; then
    bashrc_has_node_lines=true
fi

# ── Check there is anything to do ─────────────────────────────────────────────

if [[ "$node_installed" == false && "$clone_present" == false \
      && -z "$nemoclaw_symlink" && -z "$npm_bin_nemoclaw" \
      && "$bashrc_has_node_lines" == false ]]; then
    echo ""
    echo "Nothing to remove — Node.js and NemoClaw CLI do not appear to be installed."
    echo ""
    exit 0
fi

# ── Preview ────────────────────────────────────────────────────────────────────

echo ""
echo "Node.js / NemoClaw CLI Uninstaller"
echo "JetsonHacks — https://github.com/JetsonHacks/NemoClaw-Thor"
echo ""
echo "The following will be removed:"
echo ""

[[ "$clone_present" == true ]] && \
    echo "  • NemoClaw clone: ${NEMOCLAW_CLONE_DIR} (npm unlink + rm -rf)"
[[ -n "$nemoclaw_symlink" ]] && \
    echo "  • nemoclaw symlink: ${nemoclaw_symlink}"
[[ -n "$npm_bin_nemoclaw" ]] && \
    echo "  • nemoclaw in npm global bin: ${npm_bin_nemoclaw}"
[[ "$node_installed" == true ]] && \
    echo "  • nodejs package (via apt)"
[[ "$nodesource_present" == true ]] && \
    echo "  • NodeSource apt source: ${NODESOURCE_LIST}"
[[ "$bashrc_has_node_lines" == true ]] && \
    echo "  • Node/NemoClaw PATH lines from: ${BASHRC}"

echo ""
echo "  Does NOT remove: Docker, OpenShell, or other system packages."
echo ""

read -rp "Proceed? [y/N] " response
echo ""
[[ "${response}" =~ ^[Yy]$ ]] || { echo "Cancelled — nothing was changed."; echo ""; exit 0; }

# ── Step 1: npm unlink ─────────────────────────────────────────────────────────

log "Step 1: Removing NemoClaw npm link"

if [[ "$clone_present" == true ]]; then
    (
        cd "$NEMOCLAW_CLONE_DIR"
        npm unlink --ignore-scripts 2>/dev/null && pass "npm unlink succeeded" || \
            warn "npm unlink returned an error — continuing"
    )
else
    pass "Clone directory not found — skipping npm unlink"
fi

if [[ -n "$nemoclaw_symlink" ]]; then
    rm -f "$nemoclaw_symlink"
    pass "Removed symlink: ${nemoclaw_symlink}"
fi

if [[ -n "$npm_bin_nemoclaw" ]]; then
    rm -f "$npm_bin_nemoclaw"
    pass "Removed: ${npm_bin_nemoclaw}"
fi

# ── Step 2: Remove NemoClaw clone ─────────────────────────────────────────────

log "Step 2: Removing NemoClaw clone directory"

if [[ "$clone_present" == true ]]; then
    rm -rf "$NEMOCLAW_CLONE_DIR"
    [[ ! -d "$NEMOCLAW_CLONE_DIR" ]] && pass "Removed ${NEMOCLAW_CLONE_DIR}" || \
        { warn "Could not remove ${NEMOCLAW_CLONE_DIR}"; exit 1; }
else
    pass "Clone directory not found — nothing to remove"
fi

# ── Step 3: Remove Node.js ─────────────────────────────────────────────────────

log "Step 3: Removing Node.js"

if [[ "$node_installed" == true ]]; then
    sudo apt-get remove -y nodejs
    sudo apt-get autoremove -y
    pass "nodejs removed"
else
    pass "nodejs not installed via apt — skipping"
fi

if [[ "$nodesource_present" == true ]]; then
    sudo rm -f "$NODESOURCE_LIST"
    pass "Removed NodeSource apt source"
fi

# ── Step 4: Clean ~/.bashrc ────────────────────────────────────────────────────

log "Step 4: Cleaning ~/.bashrc"

if [[ -f "$BASHRC" ]]; then
    cp "$BASHRC" "${BASHRC}.uninstall-node.bak"
    info "Backup saved: ${BASHRC}.uninstall-node.bak"

    python3 - "$BASHRC" <<'PY'
import sys

path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

remove_patterns = [
    'NemoClaw',
    'nemoclaw',
    'npm config get prefix',
    '.local/bin',
    'jetson-orin.env',
]

original_count = len(lines)
filtered = [line for line in lines
            if not any(p in line for p in remove_patterns)]

# Strip trailing blank lines, restore single trailing newline
while filtered and filtered[-1].strip() == '':
    filtered.pop()
if filtered:
    filtered.append('\n')

with open(path, 'w') as f:
    f.writelines(filtered)

removed = original_count - len(filtered)
print(f"      Removed {removed} line(s) from {path}")
PY

    pass ".bashrc cleaned"
else
    warn "${BASHRC} not found — skipping"
fi

# ── Step 5: Verify ─────────────────────────────────────────────────────────────

log "Step 5: Verification"
echo ""

if command -v node >/dev/null 2>&1; then
    warn "'node' is still in PATH in this shell — open a new terminal to confirm removal"
    info "Found at: $(command -v node)"
else
    pass "node not found in PATH"
fi

if command -v npm >/dev/null 2>&1; then
    warn "'npm' is still in PATH in this shell — open a new terminal to confirm removal"
    info "Found at: $(command -v npm)"
else
    pass "npm not found in PATH"
fi

if command -v nemoclaw >/dev/null 2>&1; then
    warn "'nemoclaw' is still in PATH in this shell — open a new terminal to confirm removal"
    info "Found at: $(command -v nemoclaw)"
else
    pass "nemoclaw not found in PATH"
fi

# ── Done ───────────────────────────────────────────────────────────────────────

echo ""
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "  Node.js and NemoClaw CLI have been removed."
echo ""
echo "  IMPORTANT: Open a new terminal before running setup again."
echo "  The current shell still has stale PATH entries."
echo ""
echo "  .bashrc backup: ${BASHRC}.uninstall-node.bak"
echo "  Review and delete when satisfied."
echo ""
echo "  To reinstall:"
echo "    ./setup-jetson-orin.sh"
echo ""
