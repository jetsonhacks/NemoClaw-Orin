# NemoClaw on Jetson Orin

Local helper scripts for running NemoClaw on a Jetson Orin with a pinned OpenShell cluster image.

See the JetsonHacks article: https://wp.me/p7ZgI9-3Uv

NemoClaw and OpenShell are still moving targets. Expect breakage, and expect these scripts to evolve as the upstream stack changes.

## Why this exists

This repository exists to make NemoClaw usable on Jetson Orin without requiring the user to rediscover the same platform-specific issues each time.

There are two main jobs here.

The first is **day-0 bringup**:

* prepare the Jetson host
* install the required CLIs
* pin and select an OpenShell cluster image
* run NemoClaw onboarding in a more controlled way

The second is **day-2 recovery**:

* bring the OpenShell gateway substrate back after reboot
* restore access to an existing sandbox
* restore the user-facing OpenClaw path for that sandbox

The current bootstrap target is OpenShell `v0.0.22`.

That matters because upstream `v0.0.22` now persists the SSH handshake secret and restores sandbox state across gateway stop/start cycles, so this repository no longer treats a local gateway-image patch as part of the default setup.

OpenShell CLI installation is handled here using the upstream `install.sh` path rather than `uv tool install`, because the current `openshell` Python package wheels are not a good fit for the typical Jetson Ubuntu 22.04 / glibc 2.35 environment.

> [!IMPORTANT]
> **Do not remove the `~/NemoClaw` repository.** NemoClaw onboarding stages its Docker build context from that directory at runtime. If it is removed, `onboard-nemoclaw.sh` will fail and the sandbox cannot be rebuilt.

## Quick start

```bash
./setup-jetson-orin.sh
source ~/.bashrc
./onboard-nemoclaw.sh
```

It takes ~ 12 minutes to build and install the gateway image on a Jetson Orin Nano. 

> [!WARNING]
> **Stop Ollama and other large Docker containers before running `onboard-nemoclaw.sh`.**
> The most memory-intensive step is the sandbox image push into the gateway's k3s store. On smaller Jetson systems, that can collide with other resident workloads and trigger an OOM kill.
>
> For example, if you are using Docker-managed Ollama:
>
> ```bash
> docker stop ollama
> ```
>
> If you are using host-managed Ollama instead:
>
> ```bash
> sudo systemctl stop ollama
> ```
>
> You can restart it after `nemoclaw <sandbox-name> connect` succeeds.

## What to expect

### `setup-jetson-orin.sh`

This script prepares the host for OpenShell and NemoClaw on Jetson Orin.

It:

* installs or verifies Node.js and npm
* installs or verifies the OpenShell CLI
* installs or verifies the NemoClaw CLI
* applies the reusable host prerequisite setup
* verifies Docker and bridge netfilter state
* discovers the current upstream OpenShell cluster version
* verifies that the pinned upstream OpenShell cluster image is available locally
* writes the `OPENSHELL_CLUSTER_IMAGE` environment override so future shells use the intended upstream image automatically

### `onboard-nemoclaw.sh`

This script runs NemoClaw onboarding with extra guardrails around the Jetson environment.

It:

* checks memory and swap state
* warns when swap is likely too small
* optionally stops host k3s to reduce memory pressure
* checks that the selected OpenShell image is available locally
* checks for port conflicts
* runs `nemoclaw onboard`

### `restart-nemoclaw.sh`

This script restores the outer OpenShell side of the system after reboot.

It:

* loads the OpenShell environment override
* ensures the gateway container is running
* selects the intended gateway
* waits for the gateway API to become ready
* waits for the control-plane pod to become ready
* attempts to start NemoClaw-managed services

### `recover-sandbox.sh`

This script restores the user-facing path for an existing sandbox after reboot.

It:

* restores outer infrastructure unless told to skip it
* starts the inner OpenClaw gateway through the OpenShell user-facing path
* verifies whether the user-facing path is already healthy
* prefers the CLI approval path when available
* verifies that the user-facing path is healthy again

## Requirements

Before running these scripts, the Jetson should already have:

* Docker available and working
* Python 3
* `curl`

Node.js/npm, OpenShell CLI, and NemoClaw CLI are installed by `setup-jetson-orin.sh` if they are missing.

## Using the repository

### Day-0 bringup

For a first-time setup:

```bash
./setup-jetson-orin.sh
source ~/.bashrc
./onboard-nemoclaw.sh
```

After onboarding completes, connect to the sandbox in the normal way:

```bash
nemoclaw <sandbox-name> connect
openclaw tui
```

### Day-2 recovery after reboot

For an existing sandbox after reboot, the normal recovery command is:

```bash
./recover-sandbox.sh <sandbox-name>
```

By default, `recover-sandbox.sh` restores the outer OpenShell infrastructure as part of its recovery process.

If you only want to restore the outer OpenShell gateway substrate, you can run:

```bash
./restart-nemoclaw.sh
```

When debugging reboot problems, it is often useful to run the more explicit sequence so the outer and inner phases can be inspected separately:

```bash
./restart-nemoclaw.sh --debug
./recover-sandbox.sh <sandbox-name> --skip-outer-restart --debug
```

After recovery succeeds, use the normal user-facing workflow:

```bash
nemoclaw <sandbox-name> connect
openclaw tui
```

Browser access depends on a host-side forward. Use this helper directly if you
need to check or restore browser forwarding:

```bash
./forward-openclaw.sh <sandbox-name>
```

## Important warning about gateway startup

> [!WARNING]
> **Do not use `openshell gateway start` to resume NemoClaw after a reboot.**
> That can create a second gateway named `openshell`, conflict on port 8080, and force a more destructive recovery path.
>
> Use the repo recovery helpers instead:
>
> ```bash
> ./restart-nemoclaw.sh
> ./recover-sandbox.sh <sandbox-name>
> ```

## Repository layout

Most users only need the scripts in the repository root. The `lib/` scripts are used automatically by the top-level helpers, and can also be run directly for debugging.

Use the directories this way:

* repository root — normal day-0 bringup and day-2 recovery commands
* `lib/bootstrap/` — install-time and first-run setup helpers
* `lib/` — active internal helpers that support the main recovery/runtime flow
* `lib/maintenance/` — occasional maintenance, teardown, and debugging tools that are not part of the standard happy path

### Top-level scripts

* `setup-jetson-orin.sh` — prepare the host, install tools, verify the pinned OpenShell cluster image, and write the environment override
* `onboard-nemoclaw.sh` — run NemoClaw onboarding with Jetson-oriented checks and guardrails
* `restart-nemoclaw.sh` — restore the outer OpenShell gateway substrate after reboot
* `recover-sandbox.sh` — restore the user-facing path for an existing sandbox after reboot
* `forward-openclaw.sh` — ensure, check, or stop the OpenClaw browser forward

### Important helper scripts

* `lib/start-openclaw-gateway-via-ssh.sh` — start the inner OpenClaw gateway through the OpenShell user-facing path
* `lib/map-openclaw-cli-approval-target.sh` — map local state to a safe CLI approval target
* `lib/apply-openclaw-cli-approval.sh` — approve the matching CLI request when safe
* `lib/verify-openclaw-user-path.sh` — verify that the recovered user-facing path is healthy

### Bootstrap helpers

These live under `lib/bootstrap/` because they are primarily used during installation and host preparation.

* `lib/bootstrap/install-nodejs.sh` — install or verify Node.js and npm
* `lib/bootstrap/install-openshell-cli.sh` — install or verify the OpenShell CLI
* `lib/bootstrap/install-nemoclaw-cli.sh` — install or verify the NemoClaw CLI
* `lib/bootstrap/setup-openshell-host-prereqs.sh` — apply the reusable host prerequisites for Jetson
* `lib/bootstrap/install-docker-jetson.sh` — install Docker and NVIDIA container runtime on Jetson when needed

### Debugging helpers

These live under `lib/maintenance/` to keep the primary helper surface smaller.

* `lib/maintenance/inspect-openclaw-state.sh` — inspect durable local OpenClaw identity and pairing state during debugging
* `lib/maintenance/repair-openclaw-operator-pairing.sh` — lower-level pairing repair helper for manual recovery/debugging
* `lib/maintenance/fix-coredns.sh` — patch CoreDNS when in-cluster DNS is broken
* `lib/maintenance/uninstall-nemoclaw-openshell.sh` — remove the installed Jetson/OpenShell/NemoClaw stack
* `lib/maintenance/uninstall-setup-jetson-orin.sh` — remove setup state from this repository’s bootstrap flow
* `lib/maintenance/uninstall-node.sh` — remove Node.js and linked CLI state

## More details

* [docs/scripts.md](docs/scripts.md)
* [docs/troubleshooting.md](docs/troubleshooting.md)
* [docs/maintenance.md](docs/maintenance.md)

## Releases

### v0.0.3 April, 2026

* Tested on Jetson AGX Orin, Orin Nano
* Bootstrap target moved to OpenShell `v0.0.22`
* Default setup now uses the upstream cluster image instead of a locally patched one
* OpenShell now handles SSH handshake persistence upstream
* OpenShell now persists sandbox state across gateway stop/start cycles

### Initial Release March, 2026

* tested on Jetson Orin Nano
* NemoClaw and OpenShell are in early development, expect breakage
