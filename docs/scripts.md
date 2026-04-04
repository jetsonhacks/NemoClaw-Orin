# Scripts

This repository intentionally exposes scripts in four layers:

- repository root for normal operator workflows
- `lib/bootstrap/` for install-time and first-run setup helpers
- `lib/` for active recovery/runtime helper scripts
- `lib/maintenance/` for occasional debugging, teardown, and maintenance tools

## Root workflows

### `setup-jetson-orin.sh`

Main one-shot setup entry point.

What it does:

- installs or verifies Node.js and npm
- installs or verifies the OpenShell CLI
- installs or verifies the NemoClaw CLI with `npm`
- runs `lib/bootstrap/setup-openshell-host-prereqs.sh`
- verifies Docker and host networking state
- determines the latest upstream OpenShell cluster version
- verifies or pulls the pinned upstream image such as `ghcr.io/nvidia/openshell/cluster:0.0.22`
- writes `~/.config/openshell/jetson-orin.env`
- adds the required shell environment blocks to `~/.bashrc`

What it does not do:

- does not run `openshell gateway start`
- does not run `nemoclaw onboard`

### `onboard-nemoclaw.sh`

Runs NemoClaw onboarding with extra checks around tooling, memory, swap, port conflicts, and image validation.

### `restart-nemoclaw.sh`

Restores the outer OpenShell gateway substrate after reboot.

### `recover-sandbox.sh`

Restores the user-facing path for an existing sandbox after reboot.

### `forward-openclaw.sh`

Manages browser forwarding for OpenClaw.

What it does:

- defaults to ensuring a host-side forward is active for `127.0.0.1:18789`
- supports `--status` to report forwarding state
- supports `--stop` to stop the background forward
- supports `--bind <bind:port>` for alternate bind targets
- verifies a host listener is present before declaring success

## Bootstrap helpers

### `lib/bootstrap/setup-openshell-host-prereqs.sh`

Applies host-level prerequisites used by OpenShell and NemoClaw on Jetson Orin.

What it does:

- enables `br_netfilter`
- persists bridge netfilter sysctls
- sets Docker `default-cgroupns-mode=host`
- can optionally disable Docker IPv6
- restarts Docker and verifies resulting state

What it does not do:

- does not require or load `iptable_raw`
- does not switch host `iptables` alternatives
- does not flush host firewall rules

### `lib/bootstrap/install-nodejs.sh`

Installs or verifies Node.js and npm for the bootstrap flow.

### `lib/bootstrap/install-openshell-cli.sh`

Installs or verifies the OpenShell CLI during bootstrap.

### `lib/bootstrap/install-nemoclaw-cli.sh`

Installs or verifies the NemoClaw CLI during bootstrap.

### `lib/bootstrap/install-docker-jetson.sh`

Installs Docker and the NVIDIA container runtime on Jetson hosts when needed.

## Runtime helpers

### `lib/check-openshell-cluster-update.sh`

Checks the latest upstream OpenShell release.

Modes:

- default: prints a human-readable update report
- `--latest-version`: prints only the normalized latest upstream version for use by `setup-jetson-orin.sh`

### `lib/start-openclaw-gateway-via-ssh.sh`

Starts the inner OpenClaw gateway through the OpenShell user-facing SSH path.

### `lib/verify-openclaw-user-path.sh`

Verifies whether the user-facing OpenClaw path is already healthy.

### `lib/map-openclaw-cli-approval-target.sh`

Maps the local durable device state to a safe CLI approval target when possible.

### `lib/apply-openclaw-cli-approval.sh`

Applies the matching CLI approval through the user-facing path when it is safe to do so.

### `lib/openclaw-user-path.sh`

Shared SSH-context and health-probe helpers used by the runtime recovery scripts.

### `lib/script-ui.sh`

Shared UI/logging helpers and container state checks used across scripts.

### `lib/sandbox-kexec.sh`

Shared helper for executing commands inside the sandbox pod via `kubectl exec`.

### `lib/component-versions.sh`

Central compatibility and version pin definitions for this repository.

## Maintenance helpers

### `lib/maintenance/fix-coredns.sh`

Patches the k3s CoreDNS configuration inside the OpenShell gateway container to
forward to a real non-loopback upstream DNS server.

Use it when the gateway cluster is up but in-cluster DNS appears broken.

### `lib/maintenance/inspect-openclaw-state.sh`

Inspects durable local OpenClaw identity and pairing state during debugging.

### `lib/maintenance/repair-openclaw-operator-pairing.sh`

Lower-level pairing repair helper for manual recovery/debugging.

### `lib/maintenance/uninstall-nemoclaw-openshell.sh`

Removes the installed Jetson/OpenShell/NemoClaw stack and related state.

### `lib/maintenance/uninstall-setup-jetson-orin.sh`

Removes setup state created by this repository’s bootstrap flow.

### `lib/maintenance/uninstall-node.sh`

Removes Node.js and linked CLI state.
