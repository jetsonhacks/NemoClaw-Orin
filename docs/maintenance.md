# Maintenance

## Checking for upstream updates

To see whether your pinned patched image is behind upstream OpenShell:

```bash
./check-openshell-cluster-update.sh
```

For machine-readable version output:

```bash
./check-openshell-cluster-update.sh --latest-version
```

If a newer upstream release is available, rebuild your patched image and update the environment override by running:

```bash
./setup-jetson-orin.sh
```

## Environment variables

### Written by `setup-jetson-orin.sh`

The environment file exports:

```bash
export OPENSHELL_CLUSTER_IMAGE=openshell-cluster:jetson-legacy-<version>
export OPENSHELL_CLUSTER_VERSION=<version>
```

These are loaded automatically for future shells through `~/.bashrc`.

### Supported overrides

Examples:

```bash
REQUIRE_LEGACY_HOST_IPTABLES=false ./setup-jetson-orin.sh
SET_DOCKER_IPV6=true ./setup-openshell-host-prereqs.sh
FREE_PORT_CHECK_ONLY=true ./onboard-nemoclaw.sh
STOP_HOST_K3S=false ./onboard-nemoclaw.sh
NODE_MAJOR=22 ./setup-jetson-orin.sh
```
