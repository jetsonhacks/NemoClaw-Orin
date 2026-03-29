# NemoClaw on Jetson Orin

Local helper scripts for running NemoClaw on a Jetson Orin with a patched OpenShell cluster image.

NemoClaw and OpenShell are still moving targets. Expect breakage, and expect these scripts to evolve as the upstream stack changes.

## Why this exists

This repository exists to make NemoClaw usable on Jetson Orin without requiring the user to rediscover the same platform-specific issues each time.

There are two main jobs here.

The first is **day-0 bringup**:

* prepare the Jetson host
* install the required CLIs
* build and select a patched local OpenShell cluster image
* run NemoClaw onboarding in a more controlled way

The second is **day-2 recovery**:

* bring the OpenShell gateway substrate back after reboot
* restore access to an existing sandbox
* restore the user-facing OpenClaw path for that sandbox

The patched local OpenShell cluster image exists for two reasons in this setup:

1. **iptables-legacy**
   On this Jetson setup, the OpenShell cluster image needs to use `iptables-legacy` internally.

2. **SSH handshake secret persistence**
   The gateway substrate needs to preserve the SSH handshake secret it uses to re-establish the user-facing path to an existing sandbox after restart.

OpenShell CLI installation is handled here using the upstream `install.sh` path rather than `uv tool install`, because the current `openshell` Python package wheels are not a good fit for the typical Jetson Ubuntu 22.04 / glibc 2.35 environment.

> [!IMPORTANT]
> **Do not remove the `~/NemoClaw` repository.** NemoClaw onboarding stages its Docker build context from that directory at runtime. If it is removed, `onboard-nemoclaw.sh` will fail and the sandbox cannot be rebuilt.

## Quick start

```bash
./setup-jetson-orin.sh
source ~/.bashrc
./onboard-nemoclaw.sh
```

> [!WARNING]
> **Stop Ollama and other large Docker containers before running `onboard-nemoclaw.sh`.**
> The most memory-intensive step is the sandbox image push into the gateway's k3s store. On smaller Jetson systems, that can collide with other resident workloads and trigger an OOM kill.
>
> For example:
>
> ```bash
> docker stop ollama
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
* builds a patched local OpenShell cluster image
* writes the `OPENSHELL_CLUSTER_IMAGE` environment override so future shells use the patched image automatically

### `onboard-nemoclaw.sh`

This script runs NemoClaw onboarding with extra guardrails around the Jetson environment.

It:

* checks memory and swap state
* warns when swap is likely too small
* optionally stops host k3s to reduce memory pressure
* checks that the patched image exists locally
* rebuilds the patched image before onboarding
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
* reconciles sandbox SSH handshake state if needed
* starts the inner OpenClaw gateway through the OpenShell user-facing path
* checks pairing state
* prefers the CLI approval path when available
* falls back to lower-level repair only when needed
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
./lib/wait-for-openshell-cluster-stability.sh <sandbox-name> --debug
./recover-sandbox.sh <sandbox-name> --skip-outer-restart --debug
```

After recovery succeeds, use the normal user-facing workflow:

```bash
nemoclaw <sandbox-name> connect
openclaw tui
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

### Top-level scripts

* `setup-jetson-orin.sh` — prepare the host, install tools, build the patched OpenShell cluster image, and write the environment override
* `onboard-nemoclaw.sh` — run NemoClaw onboarding with Jetson-oriented checks and guardrails
* `restart-nemoclaw.sh` — restore the outer OpenShell gateway substrate after reboot
* `recover-sandbox.sh` — restore the user-facing path for an existing sandbox after reboot

### Important helper scripts

* `lib/wait-for-openshell-cluster-stability.sh` — wait for the cluster and sandbox to settle before inner recovery
* `lib/reconcile-sandbox-ssh-handshake.sh` — reconcile the sandbox SSH handshake state with the gateway
* `lib/start-openclaw-gateway-via-ssh.sh` — start the inner OpenClaw gateway through the OpenShell user-facing path
* `lib/inspect-openclaw-state.sh` — inspect durable local OpenClaw identity and pairing state
* `lib/map-openclaw-cli-approval-target.sh` — map local state to a safe CLI approval target
* `lib/apply-openclaw-cli-approval.sh` — approve the matching CLI request when safe
* `lib/repair-openclaw-operator-pairing.sh` — lower-level fallback pairing repair
* `lib/verify-openclaw-user-path.sh` — verify that the recovered user-facing path is healthy

## More details

* [README-reboot-recovery-scaffold.md](README-reboot-recovery-scaffold.md) — detailed reboot recovery notes and maintainer guidance
* [docs/scripts.md](docs/scripts.md)
* [docs/troubleshooting.md](docs/troubleshooting.md)
* [docs/maintenance.md](docs/maintenance.md)
* [docs/design-notes.md](docs/design-notes.md)

## Releases

### Initial Release March, 2026

* tested on Jetson Orin Nano
* NemoClaw and OpenShell are in early development, expect breakage
