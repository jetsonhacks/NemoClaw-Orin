#!/usr/bin/env bash
set -Eeuo pipefail

# Apply host-level prerequisites that are useful for OpenShell/NemoClaw on Jetson Orin:
# - enable br_netfilter
# - persist bridge netfilter sysctls
# - set Docker default-cgroupns-mode=host
# - optionally disable Docker IPv6
# - restart Docker and verify resulting state
#
# This script intentionally does NOT:
# - require or load iptable_raw
# - switch host iptables alternatives
# - flush host iptables rules
#
# Those actions were part of earlier Thor-era remediation and should not be
# applied blindly on Orin.

SET_DOCKER_IPV6="${SET_DOCKER_IPV6:-false}"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

ensure_docker_running() {
  need_cmd docker
  docker info >/dev/null 2>&1 || die "Docker daemon is not running or not accessible."
}

configure_bridge_netfilter() {
  log "Enabling bridge netfilter"
  sudo modprobe br_netfilter

  sudo tee /etc/modules-load.d/openshell-k3s.conf >/dev/null <<'EOF_MODULES'
br_netfilter
EOF_MODULES

  sudo tee /etc/sysctl.d/99-openshell-k3s.conf >/dev/null <<'EOF_SYSCTL'
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
EOF_SYSCTL

  sudo sysctl --system >/dev/null
}

merge_docker_daemon_json() {
  log "Configuring Docker daemon"
  sudo mkdir -p /etc/docker

  sudo python3 - "$SET_DOCKER_IPV6" <<'PY'
import json
import sys

set_ipv6_false = sys.argv[1].strip().lower() == "true"
config_path = "/etc/docker/daemon.json"

try:
    with open(config_path) as f:
        config = json.load(f)
except FileNotFoundError:
    config = {}
except json.JSONDecodeError as e:
    raise SystemExit(f"Invalid JSON in {config_path}: {e}")

config["default-cgroupns-mode"] = "host"

if set_ipv6_false:
    config["ipv6"] = False

with open(config_path, "w") as f:
    json.dump(config, f, indent=4)
    f.write("\n")
PY

  sudo systemctl restart docker
  docker info >/dev/null 2>&1 || die "Docker failed to restart cleanly."
}

verify_state() {
  log "Verifying host state"
  docker info | sed -n '/Cgroup/,+8p'
  iptables --version || true
  update-alternatives --display iptables || true
  lsmod | grep -E 'br_netfilter|iptable_filter|iptable_nat|ip_tables|nf_tables' || true
  sysctl net.bridge.bridge-nf-call-iptables
  sysctl net.bridge.bridge-nf-call-ip6tables

  python3 - <<'PY'
import json
path = "/etc/docker/daemon.json"
try:
    with open(path) as f:
        c = json.load(f)
except FileNotFoundError:
    c = {}
print("Docker IPv6:", c.get("ipv6", "<unset>"))
print("Docker cgroupns mode:", c.get("default-cgroupns-mode", "<unset>"))
PY
}

print_next_steps() {
  cat <<'EOF_NEXT'

Host prerequisites applied.

Next step:
  run ./setup-jetson-orin.sh

That script will verify host state again, build the patched OpenShell cluster image,
and write the OpenShell environment override file.

EOF_NEXT
}

main() {
  need_cmd sudo
  need_cmd python3
  ensure_docker_running
  configure_bridge_netfilter
  merge_docker_daemon_json
  verify_state
  print_next_steps
}

main "$@"
