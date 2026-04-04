#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/lib/script-ui.sh"

UPSTREAM_DNS="${UPSTREAM_DNS:-}"

usage() {
  cat <<'EOF'
Usage:
  ./lib/maintenance/fix-coredns.sh
  ./lib/maintenance/fix-coredns.sh <gateway-name>
  ./lib/maintenance/fix-coredns.sh --upstream 1.1.1.1

Flags:
  --upstream <ip>            Override the detected upstream DNS server
  --quiet
  --verbose
  --debug
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --upstream)
        [[ $# -ge 2 ]] || die "Missing value for --upstream"
        UPSTREAM_DNS="$2"
        shift 2
        ;;
      --quiet)
        QUIET="true"
        shift
        ;;
      --verbose)
        VERBOSE="true"
        shift
        ;;
      --debug)
        DEBUG="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        GATEWAY_NAME="$1"
        CONTAINER_NAME="openshell-cluster-${GATEWAY_NAME}"
        shift
        ;;
    esac
  done
}

kctl() {
  docker exec "$CONTAINER_NAME" kubectl "$@"
}

select_container() {
  if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
    return 0
  fi

  local matches
  matches="$(docker ps -a --format '{{.Names}}' | grep '^openshell-cluster-' || true)"
  if [[ "$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l)" -eq 1 ]]; then
    CONTAINER_NAME="$(printf '%s\n' "$matches" | sed -n '1p')"
    ui_warn "Requested container not found; using detected cluster container '$CONTAINER_NAME'"
    return 0
  fi

  die "Container '$CONTAINER_NAME' not found."
}

is_non_loopback_ip() {
  local value="$1"
  [[ -n "$value" ]] || return 1
  [[ "$value" != "127.0.0.1" ]] || return 1
  [[ "$value" != "127.0.0.11" ]] || return 1
  [[ "$value" != "127.0.0.53" ]] || return 1
  [[ "$value" != "::1" ]] || return 1
  [[ "$value" != "0.0.0.0" ]] || return 1
  return 0
}

extract_nameserver() {
  local content="$1"
  awk '/^nameserver[[:space:]]+/ {print $2}' <<<"$content" | while IFS= read -r ip; do
    if is_non_loopback_ip "$ip"; then
      printf '%s\n' "$ip"
      break
    fi
  done
}

detect_upstream_dns() {
  local container_resolv_conf host_resolv_conf candidate

  container_resolv_conf="$(docker exec "$CONTAINER_NAME" cat /etc/resolv.conf 2>/dev/null || true)"
  host_resolv_conf="$(cat /etc/resolv.conf 2>/dev/null || true)"

  candidate="$(extract_nameserver "$container_resolv_conf" || true)"
  if [[ -n "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  candidate="$(extract_nameserver "$host_resolv_conf" || true)"
  if [[ -n "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  if command -v resolvectl >/dev/null 2>&1; then
    candidate="$(resolvectl status 2>/dev/null | awk '/Current DNS Server:/ {print $NF; exit}')"
    if is_non_loopback_ip "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  printf '8.8.8.8\n'
}

patch_coredns() {
  local corefile_json
  corefile_json='{"data":{"Corefile":".:53 {\n errors\n health\n ready\n kubernetes cluster.local in-addr.arpa ip6.arpa {\n pods insecure\n fallthrough in-addr.arpa ip6.arpa\n }\n hosts /etc/coredns/NodeHosts {\n ttl 60\n reload 15s\n fallthrough\n }\n prometheus :9153\n cache 30\n loop\n reload\n loadbalance\n forward . '"$UPSTREAM_DNS"'\n}\n"}}'

  ui_step "Patching CoreDNS to forward to $UPSTREAM_DNS"
  kctl patch configmap coredns -n kube-system --type merge -p "$corefile_json" >/dev/null

  ui_step "Restarting CoreDNS"
  kctl rollout restart deploy/coredns -n kube-system >/dev/null

  ui_step "Waiting for CoreDNS rollout"
  kctl rollout status deploy/coredns -n kube-system --timeout=30s >/dev/null
}

main() {
  parse_args "$@"

  need_cmd docker
  select_container
  require_running_container

  if [[ -z "$UPSTREAM_DNS" ]]; then
    ui_step "Detecting non-loopback upstream DNS"
    UPSTREAM_DNS="$(detect_upstream_dns)"
  fi

  ui_info "Gateway container: $CONTAINER_NAME"
  ui_info "Upstream DNS:      $UPSTREAM_DNS"

  patch_coredns

  if ! is_quiet; then
    echo ""
    echo "CoreDNS patched."
    echo ""
    echo "If DNS was the blocker, wait a few seconds and retry:"
    echo "  openshell status"
    echo "  nemoclaw <sandbox-name> connect"
  fi
}

main "$@"
