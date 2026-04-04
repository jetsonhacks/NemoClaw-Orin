#!/usr/bin/env bash

openclaw_sandbox_ssh_command() {
  local sandbox_name="$1"
  shift
  local cmd="$*"
  local openshell_bin
  openshell_bin="$(command -v openshell)"
  ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o "ProxyCommand=${openshell_bin} ssh-proxy --gateway-name ${GATEWAY_NAME} --name ${sandbox_name}" \
    "sandbox@openshell-${sandbox_name}" \
    "${cmd}"
}

openclaw_ssh_env_prefix() {
  cat <<'EOF_ENV'
export HOME=/sandbox;
EOF_ENV
}

openclaw_capture_command() {
  local __outvar="$1"
  shift

  local output=""
  local rc=0
  set +e
  output="$("$@" 2>&1)"
  rc=$?
  set -e

  printf -v "$__outvar" '%s' "$output"
  return "$rc"
}

openclaw_ssh_runtime_listening() {
  local sandbox_name="$1"
  local runtime_port="$2"

  openclaw_sandbox_ssh_command "$sandbox_name" "
    $(openclaw_ssh_env_prefix)
    grep -qi ':$(printf '%04X' "$runtime_port")' /proc/net/tcp /proc/net/tcp6
  " >/dev/null 2>&1
}

openclaw_probe_gateway_health() {
  local sandbox_name="$1"

  openclaw_sandbox_ssh_command "$sandbox_name" "
    $(openclaw_ssh_env_prefix)
    openclaw gateway health
  " 2>&1
}

openclaw_health_probe_is_expected_prepair() {
  local probe_output="$1"
  printf '%s\n' "$probe_output" | grep -Eiq \
    'pair(ing)? required|not paired|unauthori[sz]ed|forbidden|auth(entication|orization)?.*required|pending'
}
