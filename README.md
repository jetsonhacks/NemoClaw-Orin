# NemoClaw on Jetson Orin

Local helper scripts for running NemoClaw on a Jetson Orin with a patched OpenShell cluster image.

NemoClaw and OpenShell are in early development, expect breakage of these scripts.

## Why this exists

The OpenShell gateway needs a patched local cluster image for two reasons specific to this Jetson setup:

1. **iptables-legacy** — the Jetson kernel only supports legacy iptables, so the gateway container must be patched to use `iptables-legacy` internally.
2. **SSH handshake secret persistence** — an upstream OpenShell bug causes a new random handshake secret to be generated on every container start, breaking all connections after a reboot. The patched image saves the secret to the k3s persistent volume on first start and reloads it on subsequent starts.

OpenShell CLI installation is handled here with the upstream `install.sh` path rather than `uv tool install`, because the current `openshell` Python package wheels are not compatible with the typical Jetson Ubuntu 22.04 / glibc 2.35 environment.

> [!IMPORTANT]
> **Do not remove the `~/NemoClaw` repository.** NemoClaw's onboarding stages its Docker build context from that directory at runtime. If it is removed, `onboard-nemoclaw.sh` will fail and the sandbox cannot be rebuilt.

## Quick start

```bash
./setup-jetson-orin.sh
source ~/.bashrc
./onboard-nemoclaw.sh
```

> [!WARNING]
> **Stop Ollama (and other large Docker containers) before running `onboard-nemoclaw.sh`.**
> The most memory-intensive step is the sandbox image push into the gateway's k3s store (~1.5 GB).
> Ollama idles at 1.5–2 GB resident on an 8 GB Jetson, and the two together are enough to trigger
> an OOM kill (exit 137) mid-push. Stop it first:
>
> ```bash
> docker stop ollama
> ```
>
> You can restart Ollama after `nemoclaw da-claw connect` succeeds.

## What to expect

- `setup-jetson-orin.sh` prepares the host, installs Node.js, OpenShell CLI, and NemoClaw CLI if missing, builds the patched local cluster image, and writes the `OPENSHELL_CLUSTER_IMAGE` environment override so future shells pick it up automatically.
- `onboard-nemoclaw.sh` runs NemoClaw onboarding with preflight checks for memory, swap, image presence, and port conflicts.

## Requirements

Before running these scripts, the Jetson should have:

- Docker available and working
- Python 3
- `curl`


Node.js/npm, OpenShell CLI, and NemoClaw CLI are installed by `setup-jetson-orin.sh` if they are missing.

## After a reboot

Use `restart-nemoclaw.sh` — do not use `openshell gateway start`:

```bash
./restart-nemoclaw.sh
nemoclaw da-claw connect
```

> [!WARNING]
> **Never use `openshell gateway start` to resume NemoClaw after a reboot.**
> That command creates a second gateway named `openshell` that conflicts on
> port 8080 and requires a full re-onboard to recover.
>
> Always use `restart-nemoclaw.sh` 
>



Most users only need the three scripts in the root. The `lib/` scripts are called automatically by `setup-jetson-orin.sh` and can also be run standalone if needed. The `image/` scripts run at Docker build time and do not need to be invoked directly.

## More details

- [docs/fix-handshake-secret.md](docs/fix-handshake-secret.md) — root cause and fix for the post-reboot SSH handshake failure
- [docs/container-identity-and-reboots.md](docs/container-identity-and-reboots.md) — how container identity and secrets survive (or don't) across restarts
- [docs/scripts.md](docs/scripts.md)
- [docs/troubleshooting.md](docs/troubleshooting.md)
- [docs/maintenance.md](docs/maintenance.md)
- [docs/design-notes.md](docs/design-notes.md)

## Releases
### Initial Release March, 2026
* Tested on Jetson Orin Nano
* NemoClaw and OpenShell are in early development, expect breakage.