#!/usr/bin/env bash
# install-docker-jetson.sh — Install Docker and NVIDIA container runtime on Jetson
#
# Installs Docker Engine and the NVIDIA container stack required to run
# GPU-enabled containers on Jetson. Safe to run multiple times — skips
# steps that are already complete.
#
# What it does:
#   - Installs Docker Engine if not already present
#   - Installs nvidia-container (NVIDIA container toolkit for Jetson) if needed
#   - Configures Docker to use the NVIDIA runtime via nvidia-ctk
#   - Optionally adds the current user to the docker group
#   - Verifies the resulting Docker + NVIDIA runtime state
#
# What it does NOT do:
#   - Install or start any inference server or model
#   - Modify kernel modules or iptables configuration
#   - Change any existing Docker daemon settings beyond the NVIDIA runtime
#
# Usage:
#   ./lib/bootstrap/install-docker-jetson.sh
#
# Optional environment overrides:
#   FORCE_REINSTALL=false           Reinstall even if already present
#   ADD_USER_TO_DOCKER_GROUP=true   Add $USER to the docker group
#
# After this script completes, you may need to log out and back in for
# docker group membership to apply if this is a first-time install.

set -euo pipefail

FORCE_REINSTALL="${FORCE_REINSTALL:-false}"
ADD_USER_TO_DOCKER_GROUP="${ADD_USER_TO_DOCKER_GROUP:-true}"

# ── Output helpers ─────────────────────────────────────────────────────────────

log()      { printf '\n==> %s\n' "$*"; }
warn()     { printf '\n[WARN] %s\n' "$*" >&2; }
die()      { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

pass() { printf '  ✓  %s\n' "$*"; }
fail() { printf '  ✗  %s\n' "$*" >&2; }

# ── Detection helpers ──────────────────────────────────────────────────────────

docker_installed() {
    command -v docker >/dev/null 2>&1
}

docker_running() {
    docker info >/dev/null 2>&1
}

docker_usable() {
    docker_installed && docker_running
}

have_pkg() {
    dpkg -s "$1" >/dev/null 2>&1
}

have_nvidia_container_stack() {
    command -v nvidia-ctk >/dev/null 2>&1 && have_pkg nvidia-container
}

# ── Header ─────────────────────────────────────────────────────────────────────

echo ""
echo "Docker + NVIDIA Runtime Installer for Jetson"
echo "JetsonHacks — https://github.com/JetsonHacks/NemoClaw-Thor"
echo ""

# ── Step 1: Install Docker ─────────────────────────────────────────────────────

log "Step 1: Docker"
echo ""

if docker_usable && [[ "${FORCE_REINSTALL}" != "true" ]]; then
    pass "Docker is already installed and running"
    docker --version | sed 's/^/       /'
else
    if docker_installed && ! docker_running; then
        warn "Docker is installed but the daemon is not running"
        log "Starting Docker daemon..."
        sudo systemctl start docker
        if docker_running; then
            pass "Docker daemon started"
        else
            die "Docker daemon failed to start. Check: sudo systemctl status docker"
        fi
    else
        need_cmd curl
        log "Installing Docker via get.docker.com..."
        echo ""
        curl -fsSL https://get.docker.com | sh
        echo ""
        sudo systemctl enable docker
        sudo systemctl start docker

        # Wait for daemon to come up
        local retries=5
        local i=0
        while [[ $i -lt $retries ]]; do
            if docker_running; then
                break
            fi
            sleep 2
            i=$((i + 1))
        done

        if ! docker_running; then
            die "Docker daemon did not start cleanly after install. Check: sudo systemctl status docker"
        fi

        pass "Docker installed and running"
        docker --version | sed 's/^/       /'
    fi
fi

# ── Step 2: Install NVIDIA container support ───────────────────────────────────

log "Step 2: NVIDIA container support"
echo ""

if have_nvidia_container_stack && [[ "${FORCE_REINSTALL}" != "true" ]]; then
    pass "NVIDIA container support is already installed"
    nvidia-ctk --version 2>/dev/null | sed 's/^/       /' || true
else
    log "Installing nvidia-container..."
    echo ""
    sudo apt-get update
    sudo apt-get install -y nvidia-container
    echo ""

    if have_nvidia_container_stack; then
        pass "NVIDIA container support installed"
        nvidia-ctk --version 2>/dev/null | sed 's/^/       /' || true
    else
        die "NVIDIA container support install appeared to succeed but nvidia-ctk or nvidia-container package is missing"
    fi
fi

# ── Step 3: Configure Docker NVIDIA runtime ────────────────────────────────────

log "Step 3: Docker NVIDIA runtime configuration"
echo ""

# nvidia-ctk runtime configure registers the NVIDIA runtime in daemon.json.
# Always run — it is idempotent.
log "Registering NVIDIA runtime via nvidia-ctk..."
sudo nvidia-ctk runtime configure --runtime=docker

# ── Step 3a: Install jq ────────────────────────────────────────────────────────

log "Step 3a: jq"
echo ""

if command -v jq >/dev/null 2>&1; then
    pass "jq is already installed ($(jq --version))"
else
    log "Installing jq..."
    sudo apt-get install -y jq
    pass "jq installed ($(jq --version))"
fi

# ── Step 3b: Set default Docker runtime to nvidia ─────────────────────────────

log "Step 3b: Set default Docker runtime to nvidia"
echo ""

DAEMON_JSON="/etc/docker/daemon.json"

# daemon.json must exist at this point — nvidia-ctk creates it above.
# If for any reason it is absent, create a minimal valid file first.
if [[ ! -f "${DAEMON_JSON}" ]]; then
    warn "${DAEMON_JSON} not found after nvidia-ctk — creating a minimal one"
    echo '{}' | sudo tee "${DAEMON_JSON}" >/dev/null
fi

if sudo jq -e '."default-runtime" == "nvidia"' "${DAEMON_JSON}" >/dev/null 2>&1; then
    pass "default-runtime is already set to nvidia in ${DAEMON_JSON}"
else
    log "Setting default-runtime to nvidia in ${DAEMON_JSON}..."
    sudo jq '. + {"default-runtime": "nvidia"}' "${DAEMON_JSON}" \
        | sudo tee "${DAEMON_JSON}.tmp" >/dev/null \
        && sudo mv "${DAEMON_JSON}.tmp" "${DAEMON_JSON}"
    pass "default-runtime set to nvidia"
fi

# Restart Docker once to pick up all daemon.json changes from Steps 3 and 3b
sudo systemctl daemon-reload
sudo systemctl restart docker

if ! docker_running; then
    die "Docker daemon did not restart cleanly after NVIDIA runtime configuration. Check: sudo systemctl status docker"
fi

pass "Docker NVIDIA runtime configured"

# ── Step 4: Add user to docker group ──────────────────────────────────────────

log "Step 4: Docker group membership"

echo ""

if [[ "${ADD_USER_TO_DOCKER_GROUP}" != "true" ]]; then
    warn "Skipping docker group setup (ADD_USER_TO_DOCKER_GROUP=${ADD_USER_TO_DOCKER_GROUP})"
elif id -nG "${USER}" | grep -qw docker; then
    pass "User ${USER} is already in the docker group"
else
    log "Adding ${USER} to the docker group..."
    sudo usermod -aG docker "${USER}"
    pass "User ${USER} added to the docker group"
    echo ""
    warn "Log out and back in (or run 'newgrp docker') for group membership to take effect."
fi

# ── Step 5: Verify ────────────────────────────────────────────────────────────

log "Step 5: Verification"
echo ""

docker info >/dev/null 2>&1 || die "Docker is not accessible after setup"

pass "Docker daemon is running"

if docker info 2>/dev/null | grep -qi 'nvidia'; then
    pass "NVIDIA runtime is visible in Docker info"
else
    warn "NVIDIA runtime entry not found in 'docker info' — the runtime may still work, but worth checking"
    echo "       Run: docker info | grep -i runtime"
fi

docker info 2>/dev/null | sed -n '/Runtimes/,+6p' | sed 's/^/       /' || true

# ── Done ───────────────────────────────────────────────────────────────────────

echo ""
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "  Docker and the NVIDIA container runtime are ready."
echo ""
echo "  To test GPU access:"
echo "    sudo docker run --rm --gpus=all ubuntu nvidia-smi"
echo ""
echo "  Next step for Ollama:"
echo "    ./providers/install-ollama-jetson.sh"
echo ""
echo "──────────────────────────────────────────────────────────────"
echo ""
echo "  Further reading — Jetson AI Lab: SSD + Docker Setup"
echo "  https://www.jetson-ai-lab.com/tutorials/ssd-docker-setup/"
echo ""
echo "  This script covers the Docker and NVIDIA runtime steps."
echo "  The Jetson AI Lab tutorial also covers:"
echo ""
echo "    • Installing and formatting an NVMe SSD"
echo "    • Migrating Docker's data directory to the SSD"
echo "      (recommended — AI containers and model weights can easily"
echo "       exceed 100GB and will fill the eMMC/SD card quickly)"
echo "    • Verifying the full setup after reboot"
echo ""
