#!/usr/bin/env bash
# install-ollama-jetson.sh — Install and run Ollama in Docker on Jetson
#
# Starts a GPU-enabled Ollama container configured for the detected JetPack
# version. Uses --runtime nvidia (required on Jetson) rather than --gpus=all,
# which invokes the NVIDIA Container Runtime Hook directly and is not
# supported on Jetson.
#
# JetPack 5 and 6 use the official ollama/ollama image. Ollama cannot
# automatically detect the JetPack version inside the container, so the
# JETSON_JETPACK environment variable is passed to select the correct GPU
# path. Reference: https://docs.ollama.com/docker
#
# JetPack 7 (Jetson AGX Thor) is not yet supported by the official
# ollama/ollama image. A separate NVIDIA-published image is used instead.
# Reference: https://www.jetson-ai-lab.com/tutorials/ollama
#
# Supported JetPack versions:
#   JetPack 7 (L4T 38.x, Jetson AGX Thor):
#     ghcr.io/nvidia-ai-iot/ollama:r38.2.arm64-sbsa-cu130-24.04
#   JetPack 6 (L4T 36.x, Jetson Orin):
#     ollama/ollama  (with JETSON_JETPACK=6)
#   JetPack 5 (L4T 35.x, Jetson Orin):
#     ollama/ollama  (with JETSON_JETPACK=5)
#
# If Docker or the NVIDIA container runtime is not yet set up, this script
# will offer to run install-docker-jetson.sh first.
#
# Usage:
#   ./install-ollama-jetson.sh
#
# After this script completes, pull a model and start using it:
#   docker exec -it ollama ollama pull llama3.2
#   docker exec -it ollama ollama run llama3.2
#
# Optional environment overrides:
#   OLLAMA_CONTAINER_NAME=ollama   Name for the Docker container
#   OLLAMA_PORT=11434              Host port (JP5/6 only; JP7 uses --network host)
#   OLLAMA_VOLUME=ollama           Docker volume name for model storage
#   OLLAMA_IMAGE=<image>           Override the image (disables auto-selection)
#   SKIP_DOCKER_INSTALL=false      Skip Docker readiness check entirely
#   ADD_USER_TO_DOCKER_GROUP=true  Passed through to install-docker-jetson.sh
#   FORCE_REINSTALL=false          Passed through to install-docker-jetson.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OLLAMA_CONTAINER_NAME="${OLLAMA_CONTAINER_NAME:-ollama}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
OLLAMA_VOLUME="${OLLAMA_VOLUME:-ollama}"
OLLAMA_IMAGE="${OLLAMA_IMAGE:-}"          # empty = auto-select by JetPack version
SKIP_DOCKER_INSTALL="${SKIP_DOCKER_INSTALL:-false}"
ADD_USER_TO_DOCKER_GROUP="${ADD_USER_TO_DOCKER_GROUP:-true}"
FORCE_REINSTALL="${FORCE_REINSTALL:-false}"

# ── Output helpers ─────────────────────────────────────────────────────────────

log()      { printf '\n==> %s\n' "$*"; }
warn()     { printf '\n[WARN] %s\n' "$*" >&2; }
die()      { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

pass() { printf '  ✓  %s\n' "$*"; }

# ── Detection helpers ──────────────────────────────────────────────────────────

docker_usable() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

nvidia_runtime_present() {
    docker info 2>/dev/null | grep -qi 'nvidia'
}

# ── Header ─────────────────────────────────────────────────────────────────────

echo ""
echo "Ollama Installer for Jetson"
echo "JetsonHacks — https://github.com/JetsonHacks/NemoClaw-Thor"
echo ""

# ── Step 1: JetPack version detection ─────────────────────────────────────────

log "Step 1: Detecting JetPack version"
echo ""

detect_jetpack_major() {
    # Prefer package metadata — most reliable when present
    local l4t_version
    l4t_version=$(dpkg-query -W -f='${Version}\n' nvidia-l4t-core 2>/dev/null || echo "")

    if echo "${l4t_version}" | grep -q '^38\.'; then
        echo 7; return 0
    fi
    if echo "${l4t_version}" | grep -q '^36\.'; then
        echo 6; return 0
    fi
    if echo "${l4t_version}" | grep -q '^35\.'; then
        echo 5; return 0
    fi

    # Fallback: /etc/nv_tegra_release
    if [[ -f /etc/nv_tegra_release ]]; then
        if grep -q 'R38' /etc/nv_tegra_release; then
            echo 7; return 0
        fi
        if grep -q 'R36' /etc/nv_tegra_release; then
            echo 6; return 0
        fi
        if grep -q 'R35' /etc/nv_tegra_release; then
            echo 5; return 0
        fi
    fi

    return 1
}

JETPACK_MAJOR=$(detect_jetpack_major) \
    || die "Unable to detect JetPack major version. This script requires JetPack 5, 6, or 7."

pass "Detected JetPack ${JETPACK_MAJOR}"

# ── Step 2: Select image and runtime configuration ────────────────────────────

log "Step 2: Selecting Ollama image"
echo ""

# JetPack 5 and 6: use the official ollama/ollama image. Ollama cannot
# detect the JetPack version automatically inside the container, so
# JETSON_JETPACK is passed explicitly. --runtime nvidia is required on
# Jetson; --gpus=all invokes the NVIDIA Container Runtime Hook directly
# which Jetson does not support.
#
# JetPack 7: not yet in the official ollama/ollama image. Use the
# NVIDIA-published image from ghcr.io/nvidia-ai-iot instead.

JETSON_JETPACK_ENV=""   # only set for JP5/6

if [[ -n "${OLLAMA_IMAGE}" ]]; then
    pass "Using image override: ${OLLAMA_IMAGE}"
else
    case "${JETPACK_MAJOR}" in
        7)
            OLLAMA_IMAGE="ghcr.io/nvidia-ai-iot/ollama:r38.2.arm64-sbsa-cu130-24.04"
            pass "JetPack 7 (Thor): using NVIDIA-published image"
            ;;
        6)
            OLLAMA_IMAGE="ollama/ollama"
            JETSON_JETPACK_ENV="6"
            pass "JetPack 6: using official ollama/ollama image with JETSON_JETPACK=6"
            ;;
        5)
            OLLAMA_IMAGE="ollama/ollama"
            JETSON_JETPACK_ENV="5"
            pass "JetPack 5: using official ollama/ollama image with JETSON_JETPACK=5"
            ;;
        *)
            die "No Ollama image is known for JetPack ${JETPACK_MAJOR}. Set OLLAMA_IMAGE manually."
            ;;
    esac
fi

echo "  Image: ${OLLAMA_IMAGE}"

# ── Step 3: Ensure Docker and NVIDIA runtime are ready ────────────────────────

log "Step 3: Docker and NVIDIA runtime"
echo ""

if [[ "${SKIP_DOCKER_INSTALL}" == "true" ]]; then
    warn "SKIP_DOCKER_INSTALL=true — skipping Docker readiness check"
    docker_usable || die "Docker is not accessible. Remove SKIP_DOCKER_INSTALL=true or run install-docker-jetson.sh first."
elif docker_usable && nvidia_runtime_present; then
    pass "Docker is running with NVIDIA runtime — no installation needed"
else
    if ! docker_usable; then
        echo "  Docker is not installed or not running."
    else
        echo "  Docker is running but the NVIDIA runtime is not configured."
    fi
    echo ""

    DOCKER_INSTALLER="${SCRIPT_DIR}/install-docker-jetson.sh"

    if [[ ! -x "${DOCKER_INSTALLER}" ]]; then
        die "install-docker-jetson.sh not found or not executable at ${DOCKER_INSTALLER}. Run it manually first, or ensure it is in the same directory as this script."
    fi

    echo "  install-docker-jetson.sh will now run to install Docker and the NVIDIA runtime."
    echo ""
    echo "  Press Enter to continue, or Ctrl-C to cancel and run it manually first."
    read -r

    ADD_USER_TO_DOCKER_GROUP="${ADD_USER_TO_DOCKER_GROUP}" \
    FORCE_REINSTALL="${FORCE_REINSTALL}" \
        "${DOCKER_INSTALLER}"

    echo ""
    docker_usable || die "Docker is still not accessible after install-docker-jetson.sh. See output above."
    pass "Docker is now ready"
fi

# ── Step 4: Pull Ollama image ─────────────────────────────────────────────────

log "Step 4: Pulling Ollama image"
echo ""
echo "  Image: ${OLLAMA_IMAGE}"
echo ""

docker pull "${OLLAMA_IMAGE}"
echo ""
pass "Image ready: ${OLLAMA_IMAGE}"

# ── Step 5: Remove any existing Ollama container ──────────────────────────────

log "Step 5: Preparing container"
echo ""

if docker ps -a --format '{{.Names}}' | grep -Fxq "${OLLAMA_CONTAINER_NAME}"; then
    echo "  Removing existing container: ${OLLAMA_CONTAINER_NAME}"
    docker rm -f "${OLLAMA_CONTAINER_NAME}"
    pass "Existing container removed"
else
    pass "No existing container named '${OLLAMA_CONTAINER_NAME}' — nothing to remove"
fi

# ── Step 6: Start Ollama container ────────────────────────────────────────────

log "Step 6: Starting Ollama container"
echo ""
echo "  Container:  ${OLLAMA_CONTAINER_NAME}"
echo "  Image:      ${OLLAMA_IMAGE}"
echo "  Runtime:    nvidia"
if [[ -n "${JETSON_JETPACK_ENV}" ]]; then
    echo "  JetPack:    ${JETSON_JETPACK_ENV} (passed as JETSON_JETPACK)"
fi
echo ""

# --runtime nvidia is required on Jetson. --gpus=all invokes the NVIDIA
# Container Runtime Hook directly, which is not supported on Jetson and
# fails with: "invoking the NVIDIA Container Runtime Hook directly is not
# supported. Please use the NVIDIA Container Runtime instead."
#
# JP7 uses --network host (no explicit port mapping) to match the
# NVIDIA-published image's expected configuration.
# JP5/6 use -p to expose the port, consistent with the official Ollama
# Docker documentation.

if [[ "${JETPACK_MAJOR}" -eq 7 ]]; then
    docker run -d \
        --runtime nvidia \
        --network host \
        -v "${OLLAMA_VOLUME}:/root/.ollama" \
        --name "${OLLAMA_CONTAINER_NAME}" \
        --restart unless-stopped \
        "${OLLAMA_IMAGE}"
else
    docker run -d \
        --runtime nvidia \
        -e "JETSON_JETPACK=${JETSON_JETPACK_ENV}" \
        -v "${OLLAMA_VOLUME}:/root/.ollama" \
        -p "${OLLAMA_PORT}:11434" \
        --name "${OLLAMA_CONTAINER_NAME}" \
        --restart unless-stopped \
        "${OLLAMA_IMAGE}"
fi

pass "Container started: ${OLLAMA_CONTAINER_NAME}"

# ── Step 7: Verify ────────────────────────────────────────────────────────────

log "Step 7: Verification"
echo ""

# Give Ollama a moment to initialize
sleep 2

docker ps --filter "name=^${OLLAMA_CONTAINER_NAME}$" \
    --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" \
    | sed 's/^/  /'

echo ""

if docker ps --filter "name=^${OLLAMA_CONTAINER_NAME}$" --filter "status=running" \
        --format '{{.Names}}' | grep -Fxq "${OLLAMA_CONTAINER_NAME}"; then
    pass "Container is running"
else
    warn "Container does not appear to be running. Check logs:"
    echo "       docker logs ${OLLAMA_CONTAINER_NAME}"
fi

# ── Done ───────────────────────────────────────────────────────────────────────

echo ""
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "  Ollama is running at http://localhost:${OLLAMA_PORT}"
echo ""
echo "  Pull a model and start using it:"
echo ""
echo "    docker exec -it ${OLLAMA_CONTAINER_NAME} ollama pull llama3.2"
echo "    docker exec -it ${OLLAMA_CONTAINER_NAME} ollama run llama3.2"
echo ""
echo "  Useful commands:"
echo "    docker logs -f ${OLLAMA_CONTAINER_NAME}"
echo "    docker exec -it ${OLLAMA_CONTAINER_NAME} ollama list"
echo "    docker stop ${OLLAMA_CONTAINER_NAME}"
echo "    docker start ${OLLAMA_CONTAINER_NAME}"
echo ""
echo "──────────────────────────────────────────────────────────────"
echo ""
echo "  Reference — Ollama Docker documentation:"
echo "  https://docs.ollama.com/docker"
echo ""
echo "  Reference — Ollama on Jetson (Jetson AI Lab):"
echo "  https://www.jetson-ai-lab.com/tutorials/ollama"
echo ""