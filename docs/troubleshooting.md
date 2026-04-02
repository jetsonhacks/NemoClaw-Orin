# Troubleshooting

## `nemoclaw` or `openshell` is not found after setup

Reload your shell environment:

```bash
source ~/.bashrc
command -v openshell || true
command -v nemoclaw || true
```

## Onboarding fails or the machine becomes unstable

Check for out-of-memory events:

```bash
dmesg -T | grep -i -E 'killed process|out of memory|oom'
free -h
swapon --show
```

Then inspect Docker and OpenShell state:

```bash
docker ps -a
openshell status || true
```

## Reboot recovery

If `openshell status` reports a connection error such as:

```text
Connection refused (os error 111)
```

the most likely cause is that the OpenShell gateway is not currently running.

In the normal case, the correct recovery procedure is to start the gateway and reconnect to the existing NemoClaw sandbox. Do not recreate the gateway unless you are intentionally resetting OpenShell state.

```bash
openshell gateway start
openshell status
nemoclaw <sandbox-name> connect
```

If you do not remember the sandbox name, list the available sandboxes first:

```bash
nemoclaw list
nemoclaw <sandbox-name> connect
```

Avoid using `openshell gateway start --recreate` for normal reboot recovery. Recreating the gateway is a destructive recovery action.

## Gateway cluster DNS looks broken

If the gateway container is running but pods cannot resolve DNS, CoreDNS may be
forwarding to a loopback resolver that is not reachable from inside k3s.

Start by checking the gateway container and cluster pods:

```bash
docker ps --format '{{.Names}}' | grep '^openshell-cluster-' || true
docker exec openshell-cluster-nemoclaw kubectl get pods -A
```

If CoreDNS is failing or restarting, apply the local CoreDNS fix and wait for
the rollout to complete:

```bash
./lib/fix-coredns.sh
```

If you need to force a specific upstream resolver:

```bash
./lib/fix-coredns.sh --upstream 1.1.1.1
```
