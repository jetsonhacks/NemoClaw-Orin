# Scripts

## `setup-jetson-orin.sh`

Main one-shot setup entry point.

What it does:

- installs or verifies Node.js and npm
- installs or verifies `uv`
- installs or verifies the OpenShell CLI with `uv`
- installs or verifies the NemoClaw CLI with `npm`
- runs `setup-openshell-host-prereqs.sh`
- verifies Docker and host networking state
- determines the latest upstream OpenShell cluster version
- builds a patched local image such as `openshell-cluster:jetson-legacy-0.0.12`
- verifies that the image reports `iptables (legacy)`
- writes `~/.config/openshell/jetson-orin.env`
- adds the required shell environment blocks to `~/.bashrc`

What it does not do:

- does not run `openshell gateway start`
- does not run `nemoclaw onboard`

## `setup-openshell-host-prereqs.sh`

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

## `Dockerfile.openshell-cluster-legacy`

Builds a local OpenShell cluster image that uses `iptables-legacy`.

## `check-openshell-cluster-update.sh`

Checks the latest upstream OpenShell release.

Modes:

- default: prints a human-readable update report
- `--latest-version`: prints only the normalized latest upstream version for use by `setup-jetson-orin.sh`

## `onboard-nemoclaw.sh`

Runs NemoClaw onboarding with extra checks around tooling, memory, swap, port conflicts, and image validation.
