#!/usr/bin/env bash
set -Eeuo pipefail

REPO_API="${REPO_API:-https://api.github.com/repos/NVIDIA/OpenShell/releases/latest}"
CURRENT_IMAGE="${OPENSHELL_CLUSTER_IMAGE:-}"
MODE="report"

log() { printf '\n==> %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

usage() {
  cat <<'EOF_USAGE'
Usage:
  check-openshell-cluster-update.sh
  check-openshell-cluster-update.sh --latest-version

Options:
  --latest-version   Print only the normalized latest upstream version (for scripts)
  -h, --help         Show this help
EOF_USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --latest-version)
      MODE="latest_version"
      shift
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

need_cmd curl
need_cmd python3

latest_tag_raw="$(curl -fsSL "$REPO_API" | python3 -c 'import sys, json; print(json.load(sys.stdin)["tag_name"])')"
latest_tag="${latest_tag_raw#v}"

if [[ "$MODE" == "latest_version" ]]; then
  printf '%s\n' "$latest_tag"
  exit 0
fi

extract_version() {
  local image="$1"
  local tag
  tag="${image##*:}"
  # Backward-compatibility with older local tags from previous script versions.
  tag="${tag#patched-}"
  tag="${tag#jetson-legacy-}"
  tag="${tag#v}"
  printf '%s\n' "$tag"
}

current_version="unknown"
if [[ -n "$CURRENT_IMAGE" ]]; then
  current_version="$(extract_version "$CURRENT_IMAGE")"
fi

log "OpenShell cluster version check"
printf 'Latest upstream release tag: %s\n' "$latest_tag_raw"
printf 'Normalized upstream version: %s\n' "$latest_tag"
printf 'Pinned OPENSHELL_CLUSTER_IMAGE: %s\n' "${CURRENT_IMAGE:-not set}"
printf 'Pinned image version: %s\n' "$current_version"

if [[ -z "$CURRENT_IMAGE" ]]; then
  warn "OPENSHELL_CLUSTER_IMAGE is not set in the current shell."
  cat <<EOF2

Suggested upstream image:
  ghcr.io/nvidia/openshell/cluster:$latest_tag
EOF2
  exit 0
fi

echo
if [[ "$current_version" == "$latest_tag" ]]; then
  echo "Pinned image appears up to date with the latest OpenShell release."
else
  echo "Update available."
  echo "Suggested new image: ghcr.io/nvidia/openshell/cluster:$latest_tag"
  echo "Update OPENSHELL_CLUSTER_IMAGE to the newer upstream tag."
fi
