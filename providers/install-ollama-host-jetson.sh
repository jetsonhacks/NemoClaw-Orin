#!/usr/bin/env bash
set -Eeuo pipefail

# install-ollama-host-jetson.sh — Install and run Ollama directly on the Jetson host
#
# This is the host-managed alternative to providers/install-ollama-jetson.sh.
# It uses Ollama's native install path instead of Docker so users can adopt
# new Ollama releases and newly supported models as soon as they are available.
#
# Intended usage:
#   ./install-ollama-host-jetson.sh
#   ./install-ollama-host-jetson.sh --model qwen3.5:9b
#
# Optional environment overrides:
#   OLLAMA_INSTALL_URL=https://ollama.com/install.sh
#   OLLAMA_HOST=127.0.0.1:11434
#   OLLAMA_BIND_HOST=0.0.0.0:11434
#   AUTO_CONFIRM=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_MANAGER_SCRIPT="${MODEL_MANAGER_SCRIPT:-$SCRIPT_DIR/manage-ollama-models.sh}"

OLLAMA_MIN_VERSION="${OLLAMA_MIN_VERSION:-0.18.0}"
OLLAMA_INSTALL_URL="${OLLAMA_INSTALL_URL:-https://ollama.com/install.sh}"
OLLAMA_HOST_VALUE="${OLLAMA_HOST:-127.0.0.1:11434}"
OLLAMA_BIND_HOST_VALUE="${OLLAMA_BIND_HOST:-0.0.0.0:11434}"
AUTO_CONFIRM="${AUTO_CONFIRM:-false}"
AUTO_PULL_RECOMMENDED_MODEL="${AUTO_PULL_RECOMMENDED_MODEL:-false}"
RECOMMEND_STARTER_MODEL="${RECOMMEND_STARTER_MODEL:-true}"
LARGE_MODEL_MIN_MEMORY_MB="${LARGE_MODEL_MIN_MEMORY_MB:-32768}"
SMALL_OLLAMA_MODEL="${SMALL_OLLAMA_MODEL:-qwen2.5:7b}"
LARGE_OLLAMA_MODEL="${LARGE_OLLAMA_MODEL:-nemotron-3-nano:30b}"

OLLAMA_MODEL=""
OLLAMA_BIN=""
RECOMMENDED_MODEL=""
TOTAL_MEMORY_MB=0
TMP_INSTALLER="/tmp/ollama-install.$$.$RANDOM.sh"
TMP_OVERRIDE="/tmp/ollama-service-override.$$.$RANDOM.conf"

log()      { printf '\n==> %s\n' "$*"; }
warn()     { printf '\n[WARN] %s\n' "$*" >&2; }
die()      { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
pass()     { printf '  ✓  %s\n' "$*"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

cleanup() {
  rm -f "$TMP_INSTALLER" "$TMP_OVERRIDE"
}
trap cleanup EXIT

usage() {
  cat <<'EOF_USAGE'
Usage:
  ./install-ollama-host-jetson.sh [--model <model-name>]

Options:
  --model <model-name>   Optional Ollama model to pull after install
  -h, --help             Show this help

Examples:
  ./install-ollama-host-jetson.sh
  ./install-ollama-host-jetson.sh --model qwen3.5:9b

Notes:
  - This is the host-managed Ollama path.
  - It is intended for users who want the native Ollama install flow and
    faster access to newly released Ollama versions and model support.
  - The installed service is configured to listen on 0.0.0.0:11434 so
    OpenShell sandboxes can reach it through host.openshell.internal.
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

confirm_install() {
  if [[ "$AUTO_CONFIRM" == "true" ]]; then
    log "AUTO_CONFIRM=true, proceeding without prompt"
    return 0
  fi

  echo ""
  echo "Ollama Host Installer for Jetson"
  echo "JetsonHacks — https://github.com/jetsonhacks/NemoClaw-Orin"
  echo ""
  echo "This installs Ollama directly on the Jetson host using the upstream"
  echo "native install path."
  echo ""
  echo "Why choose this mode:"
  echo "  - faster access to new Ollama releases"
  echo "  - day-one availability for newly supported models"
  echo "  - familiar workflow for users who already manage Ollama directly"
  echo ""
  echo "Tradeoffs compared with the Docker-managed path:"
  echo "  - less isolated from host state"
  echo "  - upgrades and rollback are more manual"
  echo "  - recovery is service-based rather than container-based"
  echo ""
  printf 'Continue with host-managed Ollama install? [y/N] '

  read -r reply
  case "${reply:-}" in
    y|Y|yes|YES)
      return 0
      ;;
    *)
      die "Operation cancelled. No changes were made."
      ;;
  esac
}

check_prereqs() {
  need_cmd curl
  need_cmd python3
}

verify_downloaded_script() {
  local file="$1"
  local label="${2:-script}"
  local hash=""

  [[ -s "$file" ]] || die "$label installer download is empty or missing."
  head -1 "$file" | grep -qE '^#!.*(sh|bash)' || \
    die "$label installer does not start with a shell shebang. The download may be corrupted."

  if command -v sha256sum >/dev/null 2>&1; then
    hash="$(sha256sum "$file" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    hash="$(shasum -a 256 "$file" | awk '{print $1}')"
  fi

  [[ -z "$hash" ]] || pass "$label installer SHA-256: $hash"
}

version_gte() {
  local left="$1"
  local right="$2"
  [[ "$(printf '%s\n%s\n' "$left" "$right" | sort -V | tail -n1)" == "$left" ]]
}

get_ollama_version() {
  local output=""
  if ! resolve_ollama_bin >/dev/null 2>&1; then
    return 1
  fi
  output="$("$OLLAMA_BIN" --version 2>/dev/null || true)"
  printf '%s\n' "$output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

resolve_ollama_bin() {
  if command -v ollama >/dev/null 2>&1; then
    OLLAMA_BIN="$(command -v ollama)"
    return 0
  fi

  for candidate in /usr/local/bin/ollama /usr/bin/ollama; do
    if [[ -x "$candidate" ]]; then
      OLLAMA_BIN="$candidate"
      return 0
    fi
  done

  return 1
}

get_total_memory_mb() {
  local kb=""
  kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || true)"
  [[ -n "$kb" ]] || {
    echo 0
    return 0
  }
  echo $((kb / 1024))
}

recommend_model() {
  TOTAL_MEMORY_MB="$(get_total_memory_mb)"
  if [[ "$TOTAL_MEMORY_MB" -ge "$LARGE_MODEL_MIN_MEMORY_MB" ]]; then
    RECOMMENDED_MODEL="$LARGE_OLLAMA_MODEL"
  else
    RECOMMENDED_MODEL="$SMALL_OLLAMA_MODEL"
  fi
}

choose_model_if_desired() {
  [[ -n "$OLLAMA_MODEL" ]] && return 0
  [[ "$RECOMMEND_STARTER_MODEL" == "true" ]] || return 0

  recommend_model

  log "Choosing a starter Ollama model"
  printf '  Detected system memory: %s MB\n' "$TOTAL_MEMORY_MB"
  printf '  Recommended starter model: %s\n' "$RECOMMENDED_MODEL"

  if [[ "$AUTO_PULL_RECOMMENDED_MODEL" == "true" ]]; then
    OLLAMA_MODEL="$RECOMMENDED_MODEL"
    pass "AUTO_PULL_RECOMMENDED_MODEL=true, will pull $OLLAMA_MODEL"
    return 0
  fi

  if [[ "$AUTO_CONFIRM" == "true" ]]; then
    return 0
  fi

  echo ""
  printf 'Pull the recommended starter model now? [y/N] '
  read -r reply
  case "${reply:-}" in
    y|Y|yes|YES)
      OLLAMA_MODEL="$RECOMMENDED_MODEL"
      ;;
    *)
      ;;
  esac
}

install_or_upgrade_ollama() {
  local current_version=""

  if resolve_ollama_bin >/dev/null 2>&1; then
    current_version="$(get_ollama_version || true)"
    if [[ -n "$current_version" ]] && version_gte "$current_version" "$OLLAMA_MIN_VERSION"; then
      log "Ollama version check"
      pass "Installed Ollama v${current_version} meets minimum requirement (>= v${OLLAMA_MIN_VERSION})"
      return 0
    fi

    log "Ollama version check"
    warn "Installed Ollama v${current_version:-unknown} is below v${OLLAMA_MIN_VERSION}; upgrading."
  fi

  log "Downloading upstream Ollama installer"
  curl --fail --location --silent --show-error \
    "$OLLAMA_INSTALL_URL" \
    --output "$TMP_INSTALLER"
  chmod +x "$TMP_INSTALLER"
  verify_downloaded_script "$TMP_INSTALLER" "Ollama"
  pass "Installer downloaded"

  log "Running upstream Ollama installer"
  if [[ "$(id -u)" -eq 0 ]]; then
    sh "$TMP_INSTALLER"
  elif command -v sudo >/dev/null 2>&1; then
    sudo sh "$TMP_INSTALLER"
  else
    die "The Ollama installer needs elevated privileges, but sudo is not available."
  fi

  resolve_ollama_bin || die "Ollama install completed, but the ollama binary was not found in PATH or common install locations."
  pass "Ollama binary detected at $OLLAMA_BIN"
  current_version="$(get_ollama_version || true)"
  [[ -z "$current_version" ]] || pass "Installed Ollama version: $current_version"
}

write_service_override() {
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl not found; cannot install a persistent Ollama bind override"
    warn "Start Ollama manually with: OLLAMA_HOST=${OLLAMA_BIND_HOST_VALUE} ollama serve"
    return 0
  fi

  log "Configuring Ollama to listen for sandbox access"
  cat >"$TMP_OVERRIDE" <<EOF
[Service]
Environment="OLLAMA_HOST=${OLLAMA_BIND_HOST_VALUE}"
EOF

  if [[ "$(id -u)" -eq 0 ]]; then
    mkdir -p /etc/systemd/system/ollama.service.d
    cp "$TMP_OVERRIDE" /etc/systemd/system/ollama.service.d/override.conf
    systemctl daemon-reload
  else
    sudo mkdir -p /etc/systemd/system/ollama.service.d
    sudo cp "$TMP_OVERRIDE" /etc/systemd/system/ollama.service.d/override.conf
    sudo systemctl daemon-reload
  fi

  pass "Installed systemd override for OLLAMA_HOST=${OLLAMA_BIND_HOST_VALUE}"
}

ensure_service_running() {
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl not found; skipping automatic service startup"
    warn "Start Ollama manually with: OLLAMA_HOST=${OLLAMA_BIND_HOST_VALUE} ollama serve"
    return 0
  fi

  log "Enabling and starting the Ollama service"
  if [[ "$(id -u)" -eq 0 ]]; then
    systemctl enable --now ollama
  else
    sudo systemctl enable --now ollama
  fi

  if systemctl is-active --quiet ollama; then
    pass "Ollama service is active"
  else
    warn "Ollama service did not report active state yet"
  fi
}

wait_for_api() {
  log "Waiting for Ollama API to become ready"
  local attempts=0
  while [[ $attempts -lt 24 ]]; do
    if OLLAMA_TAGS_URL="http://${OLLAMA_HOST_VALUE}/api/tags" "$MODEL_MANAGER_SCRIPT" --list >/dev/null 2>&1; then
      pass "Ollama API is responding at http://${OLLAMA_HOST_VALUE}"
      return 0
    fi
    sleep 2
    attempts=$((attempts + 1))
  done

  die "Ollama did not become ready at http://${OLLAMA_HOST_VALUE} within 48 seconds."
}

pull_model_if_requested() {
  [[ -n "$OLLAMA_MODEL" ]] || return 0

  log "Pulling requested model"
  OLLAMA_HOST="$OLLAMA_HOST_VALUE" "$OLLAMA_BIN" pull "$OLLAMA_MODEL"
  pass "Model ready: $OLLAMA_MODEL"
}

print_summary() {
  echo ""
  echo "══════════════════════════════════════════════════════════════"
  echo ""
  echo "  Ollama is installed directly on the host"
  echo "  API endpoint: http://${OLLAMA_HOST_VALUE}"
  echo ""
  echo "  Common commands:"
  echo "    systemctl status ollama"
  echo "    sudo systemctl restart ollama"
  echo "    sudo systemctl cat ollama"
  echo "    OLLAMA_HOST=${OLLAMA_HOST_VALUE} ollama list"
  echo "    OLLAMA_HOST=${OLLAMA_HOST_VALUE} ollama pull <model-name>"
  echo ""
  echo "  You can also use the repo model manager:"
  echo "    OLLAMA_TAGS_URL=http://${OLLAMA_HOST_VALUE}/api/tags \\"
  echo "    OLLAMA_PS_URL=http://${OLLAMA_HOST_VALUE}/api/ps \\"
  echo "    OLLAMA_PULL_URL=http://${OLLAMA_HOST_VALUE}/api/pull \\"
  echo "    OLLAMA_DELETE_URL=http://${OLLAMA_HOST_VALUE}/api/delete \\"
  echo "    ./providers/manage-ollama-models.sh"
  echo ""
  echo "  Next:"
  echo "    ./providers/configure-gateway-provider.sh --model <model-name> --activate"
  echo ""
  echo "──────────────────────────────────────────────────────────────"
  echo ""
  echo "  Reference — Ollama installation:"
  echo "  https://ollama.com/download/linux"
  echo ""
  echo "  Reference — Ollama model library:"
  echo "  https://ollama.com/library"
  echo ""
}

main() {
  parse_args "$@"
  check_prereqs
  confirm_install
  install_or_upgrade_ollama
  write_service_override
  ensure_service_running
  choose_model_if_desired
  wait_for_api
  pull_model_if_requested
  print_summary
}

main "$@"
