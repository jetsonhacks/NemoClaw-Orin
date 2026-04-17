# Maintenance

> [!IMPORTANT]
> This page mostly documents the legacy JetsonHacks install flow. New NemoClaw
> installs should follow upstream NVIDIA/NemoClaw. Use these notes only when
> cleaning up or inspecting an older JetsonHacks-managed install.

## Checking for upstream updates

To see whether your pinned OpenShell image is behind upstream OpenShell:

```bash
./lib/check-openshell-cluster-update.sh
```

For machine-readable version output:

```bash
./lib/check-openshell-cluster-update.sh --latest-version
```

For a legacy JetsonHacks-managed install, if a newer upstream release is
available, refresh the pinned image and update the environment override by
running:

```bash
./setup-jetson-orin.sh
```

## Environment variables

### Written by `setup-jetson-orin.sh`

The environment file exports:

```bash
export OPENSHELL_CLUSTER_IMAGE=ghcr.io/nvidia/openshell/cluster:<version>
export OPENSHELL_CLUSTER_VERSION=<version>
```

These are loaded automatically for future shells through `~/.bashrc`.

### Supported overrides

Examples:

```bash
OPENSHELL_CLUSTER_IMAGE_REPO=ghcr.io/nvidia/openshell/cluster ./setup-jetson-orin.sh
SET_DOCKER_IPV6=true ./lib/bootstrap/setup-openshell-host-prereqs.sh
FREE_PORT_CHECK_ONLY=true ./onboard-nemoclaw.sh
STOP_HOST_K3S=false ./onboard-nemoclaw.sh
NODE_MAJOR=22 ./setup-jetson-orin.sh
```
