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
#   ./install-ollama-jetson.sh --model <model-name>
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
OLLAMA_MODEL=""
SKIP_DOCKER_INSTALL="${SKIP_DOCKER_INSTALL:-false}"
ADD_USER_TO_DOCKER_GROUP="${ADD_USER_TO_DOCKER_GROUP:-true}"
FORCE_REINSTALL="${FORCE_REINSTALL:-false}"

log()      { printf '\n==> %s\n' "$*"; }
warn()     { printf '\n[WARN] %s\n' "$*" >&2; }
die()      { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }
pass()     { printf '  ✓  %s\n' "$*"; }

usage() {
  cat <<'EOF_USAGE'
Usage:
  ./install-ollama-jetson.sh [--model <model-name>]

Options:
  --model <model-name>   Optional Ollama model to pull after container start
  -h, --help             Show this help

Examples:
  ./install-ollama-jetson.sh
  ./install-ollama-jetson.sh --model qwen3.5:9b
EOF_USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --model)
        [[ $# -ge 2 ]] || die "--model requires a value"
        OLLAMA_MODEL="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

docker_usable() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

nvidia_runtime_present() {
  docker info 2>/dev/null | grep -qi 'nvidia'
}

detect_jetpack_major() {
  local l4t_version
  l4t_version="$(dpkg-query -W -f='${Version}\n' nvidia-l4t-core 2>/dev/null || echo "")"

  if echo "${l4t_version}" | grep -q '^38\.'; then
    echo 7
    return 0
  fi
  if echo "${l4t_version}" | grep -q '^36\.'; then
    echo 6
    return 0
  fi
  if echo "${l4t_version}" | grep -q '^35\.'; then
    echo 5
    return 0
  fi

  if [[ -f /etc/nv_tegra_release ]]; then
    if grep -q 'R38' /etc/nv_tegra_release; then
      echo 7
      return 0
    fi
    if grep -q 'R36' /etc/nv_tegra_release; then
      echo 6
      return 0
    fi
    if grep -q 'R35' /etc/nv_tegra_release; then
      echo 5
      return 0
    fi
  fi

  return 1
}

step_detect_jetpack() {
  log "Step 1: Detecting JetPack version"
  echo ""

  JETPACK_MAJOR="$(detect_jetpack_major)" \
    || die "Unable to detect JetPack major version. This script requires JetPack 5, 6, or 7."

  pass "Detected JetPack ${JETPACK_MAJOR}"
}

step_select_image() {
  log "Step 2: Selecting Ollama image"
  echo ""

  JETSON_JETPACK_ENV=""

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
}

step_check_docker() {
  log "Step 3: Docker and NVIDIA runtime"
  echo ""

  if [[ "${SKIP_DOCKER_INSTALL}" == "true" ]]; then
    warn "SKIP_DOCKER_INSTALL=true — skipping Docker readiness check"
    docker_usable || die "Docker is not accessible. Remove SKIP_DOCKER_INSTALL=true or run install-docker-jetson.sh first."
    return 0
  fi

  if docker_usable && nvidia_runtime_present; then
    pass "Docker is running with NVIDIA runtime — no installation needed"
    return 0
  fi

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
}

step_pull_image() {
  log "Step 4: Pulling Ollama image"
  echo ""
  echo "  Image: ${OLLAMA_IMAGE}"
  echo ""

  docker pull "${OLLAMA_IMAGE}"
  echo ""
  pass "Image ready: ${OLLAMA_IMAGE}"
}

step_prepare_container() {
  log "Step 5: Preparing container"
  echo ""

  if docker ps -a --format '{{.Names}}' | grep -Fxq "${OLLAMA_CONTAINER_NAME}"; then
    echo "  Removing existing container: ${OLLAMA_CONTAINER_NAME}"
    docker rm -f "${OLLAMA_CONTAINER_NAME}"
    pass "Existing container removed"
  else
    pass "No existing container named '${OLLAMA_CONTAINER_NAME}' — nothing to remove"
  fi
}

step_start_container() {
  log "Step 6: Starting Ollama container"
  echo ""
  echo "  Container:  ${OLLAMA_CONTAINER_NAME}"
  echo "  Image:      ${OLLAMA_IMAGE}"
  echo "  Runtime:    nvidia"
  if [[ -n "${JETSON_JETPACK_ENV}" ]]; then
    echo "  JetPack:    ${JETSON_JETPACK_ENV} (passed as JETSON_JETPACK)"
  fi
  echo ""

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
}

step_verify() {
  log "Step 7: Verification"
  echo ""

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
}

step_pull_model_if_requested() {
  if [[ -z "${OLLAMA_MODEL}" ]]; then
    return 0
  fi

  log "Step 8: Pulling Ollama model"
  echo ""
  echo "  Model: ${OLLAMA_MODEL}"
  echo ""

  docker exec -it "${OLLAMA_CONTAINER_NAME}" ollama pull "${OLLAMA_MODEL}"
  echo ""
  pass "Model ready: ${OLLAMA_MODEL}"
}

print_summary() {
  echo ""
  echo "══════════════════════════════════════════════════════════════"
  echo ""
  if [[ "${JETPACK_MAJOR}" -eq 7 ]]; then
    echo "  Ollama is running using host networking"
    echo "  Typical endpoint: http://localhost:11434"
  else
    echo "  Ollama is running at http://localhost:${OLLAMA_PORT}"
  fi
  echo ""
  echo "  To pull a model later, use an Ollama model name:"
  echo ""
  echo "    docker exec -it ${OLLAMA_CONTAINER_NAME} ollama pull <model-name>"
  echo "    docker exec -it ${OLLAMA_CONTAINER_NAME} ollama run <model-name>"
  echo ""
  echo "  To pull a model during install:"
  echo ""
  echo "    ./install-ollama-jetson.sh --model <model-name>"
  echo ""
  echo "  Browse available Ollama models:"
  echo "  https://ollama.com/library"
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
  echo "  Reference — Ollama model library:"
  echo "  https://ollama.com/library"
  echo ""
  echo "  Reference — Ollama on Jetson (Jetson AI Lab):"
  echo "  https://www.jetson-ai-lab.com/tutorials/ollama"
  echo ""
}

main() {
  parse_args "$@"

  echo ""
  echo "Ollama Installer for Jetson"
  echo "JetsonHacks — https://github.com/jetsonhacks/NemoClaw-Orin"
  echo ""

  need_cmd dpkg

  step_detect_jetpack
  step_select_image
  step_check_docker
  step_pull_image
  step_prepare_container
  step_start_container
  step_verify
  step_pull_model_if_requested
  print_summary
}

main "$@"