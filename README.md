# NemoClaw on Jetson Orin

Scripts and documentation for running NemoClaw on NVIDIA Jetson Orin systems with OpenShell.

This repository packages the Jetson-specific setup and recovery work that is easy to get wrong when following the upstream tools directly.

See the JetsonHacks article: <https://wp.me/p7ZgI9-3Uv>

## Overview

This project is for people who want a more reliable NemoClaw workflow on Jetson Orin.

It focuses on:

- preparing a Jetson host for OpenShell and NemoClaw
- installing the required CLIs
- running onboarding with Jetson-oriented guardrails
- recovering an existing sandbox after reboot
- configuring local or alternate inference providers
- measuring direct local-model performance with standalone benchmarks

The default bootstrap target in this repository is OpenShell `v0.0.22`.

## Related Upstream Projects

- OpenShell: <https://github.com/NVIDIA/OpenShell>
- NemoClaw: <https://github.com/NVIDIA/NemoClaw>

## Who This Is For

This repository is useful if you are:

- setting up NemoClaw on a Jetson Orin for the first time
- trying to avoid repeating Jetson-specific OpenShell setup steps manually
- recovering an existing NemoClaw sandbox after restart or reboot
- switching `inference.local` to Ollama, NVIDIA Endpoints, or another compatible provider

## Main Scripts

The main operator commands are:

- `./setup-jetson-orin.sh`
  Prepare the host, install tools, verify the selected OpenShell image, and write the environment override.
- `./onboard-nemoclaw.sh`
  Run NemoClaw onboarding with checks around memory, swap, image availability, and port conflicts.
- `./restart-nemoclaw.sh`
  Restore the outer OpenShell gateway substrate after reboot.
- `./recover-sandbox.sh`
  Restore the user-facing path for an existing sandbox after reboot.
- `./forward-openclaw.sh`
  Ensure, inspect, or stop the browser forward used by OpenClaw.

## Prerequisites

Docker is often already installed as well, but that is not guaranteed on every system.

If Docker is missing, or if the NVIDIA container runtime is not configured correctly for Jetson, use:

```bash
./lib/bootstrap/install-docker-jetson.sh
```

After Docker is installed, add your user to the `docker` group so you can run Docker without `sudo`:

```bash
sudo usermod -aG docker "$USER"
newgrp docker
```

If you prefer, you can log out and log back in instead of running `newgrp docker`.

`setup-jetson-orin.sh` installs or verifies Node.js, the OpenShell CLI, and the NemoClaw CLI. It also checks the local Docker/OpenShell prerequisites used by the rest of this workflow.

## Quick Start

For a first-time setup:

```bash
./setup-jetson-orin.sh
source ~/.bashrc
./onboard-nemoclaw.sh
```

After onboarding completes:

```bash
./providers/configure-gateway-provider.sh --status
nemoclaw <sandbox-name> connect
openclaw tui
```

If `--status` shows that gateway inference is not configured, restore the onboarding selection or pick a local model before opening the UI:

```bash
openshell inference set --provider <onboarding-provider> --model <onboarding-model> --no-verify
# or
./providers/configure-ollama-local.sh --model <model-name>
```

## Common Workflows

### Recover after reboot

```bash
./recover-sandbox.sh <sandbox-name>
```

If you only need to restore the outer OpenShell layer:

```bash
./restart-nemoclaw.sh
```

For a more explicit debug flow:

```bash
./restart-nemoclaw.sh --debug
./recover-sandbox.sh <sandbox-name> --skip-outer-restart --debug
```

## Important Notes

> [!IMPORTANT]
> Do not remove the `~/NemoClaw` clone. NemoClaw stages its Docker build context from that directory during onboarding.

> [!WARNING]
> Stop Ollama and other large Docker workloads before running `./onboard-nemoclaw.sh` on smaller Jetson systems. The onboarding path can become memory-heavy during image import and push.

Docker-managed Ollama:

```bash
docker stop ollama
```

Host-managed Ollama:

```bash
sudo systemctl stop ollama
```

Restart it after `nemoclaw <sandbox-name> connect` succeeds.

> [!WARNING]
> Do not use raw `openshell gateway start` for normal NemoClaw reboot recovery. Use the repository recovery helper instead:
>
> ```bash
> ./recover-sandbox.sh <sandbox-name>
> ```

## Providers

After onboarding, the scripts under `providers/` can point `inference.local` at:

- a local Ollama instance
- a local vLLM server
- NVIDIA Endpoints
- another OpenAI-compatible endpoint

Provider details and examples live in [providers/README_PROVIDERS.md](providers/README_PROVIDERS.md).

## Repository Structure

- `./`
  Main operator workflows.
- `lib/bootstrap/`
  Install-time and first-run helpers.
- `lib/`
  Shared runtime and recovery helpers.
- `lib/maintenance/`
  Lower-level debugging, teardown, and maintenance tools.
- `providers/`
  Inference provider management scripts.
- `benchmarks/`
  Standalone direct-provider benchmark helpers.
- `docs/`
  Supporting references and troubleshooting guides.

## Documentation

- [docs/scripts.md](docs/scripts.md)
- [docs/troubleshooting.md](docs/troubleshooting.md)
- [docs/maintenance.md](docs/maintenance.md)
- [docs/rca/2026-04-04-nemoclaw-374a847-regression.md](docs/rca/2026-04-04-nemoclaw-374a847-regression.md)
- [docs/adr/0001-inference-timeout.md](docs/adr/0001-inference-timeout.md)
- [docs/adr/0002-cli-pairing-auto-approval.md](docs/adr/0002-cli-pairing-auto-approval.md)
- [providers/README_PROVIDERS.md](providers/README_PROVIDERS.md)
- [benchmarks/README.md](benchmarks/README.md)

## Release Notes

### v0.0.4 April, 2026

- add automatic local CLI pairing approval after onboard and recovery
- re-apply a 120-second OpenShell managed inference timeout during onboard and recovery
- restore the onboarding-selected provider/model when gateway inference is unset after onboard
- add direct Ollama benchmark tooling under `benchmarks/`
- document the regression investigation and local decisions with RCA and ADR records

Tested with:

- OpenShell `v0.0.22`
- NemoClaw commit `374a847`

### v0.0.3 April, 2026

- tested on Jetson AGX Orin and Orin Nano
- bootstrap target moved to OpenShell `v0.0.22`
- default setup now uses the upstream cluster image instead of a locally patched image
- OpenShell now handles SSH handshake persistence upstream
- OpenShell now persists sandbox state across gateway stop and start cycles

### v0.0.2 April, 2026

- tested on Jetson AGX Orin and Orin Nano
- moved to OpenShell `v0.0.20`

### Initial Release March, 2026

- tested on Jetson Orin Nano
- initial Jetson-oriented NemoClaw bringup and recovery workflow

## Project Status

NemoClaw and OpenShell are evolving quickly. This repository tracks a tested Jetson-oriented workflow, but some upstream behavior may change over time.
