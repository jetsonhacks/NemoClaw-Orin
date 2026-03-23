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
