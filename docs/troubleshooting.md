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

In the normal case, the correct recovery procedure is to use this repository's recovery helpers to restore the gateway substrate and reconnect to the existing NemoClaw sandbox. Do not recreate the gateway unless you are intentionally resetting OpenShell state.

```bash
./restart-nemoclaw.sh
./recover-sandbox.sh <sandbox-name>
nemoclaw <sandbox-name> connect
```

If you do not remember the sandbox name, list the available sandboxes first:

```bash
nemoclaw list
./recover-sandbox.sh <sandbox-name>
nemoclaw <sandbox-name> connect
```

Avoid using `openshell gateway start` or `openshell gateway start --recreate` for normal reboot recovery. Recreating the gateway is a destructive recovery action, and a plain raw start can create a second gateway named `openshell` and conflict with the existing NemoClaw path.

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
./lib/maintenance/fix-coredns.sh
```

If you need to force a specific upstream resolver:

```bash
./lib/maintenance/fix-coredns.sh --upstream 1.1.1.1
```

## `openclaw tui` says `Pairing required`

This repository includes a local pairing recovery workflow because pairing
problems have recurred during Jetson NemoClaw debugging.

Start by capturing current state and checking whether the repo's approval mapper
can identify a safe request to approve:

```bash
./tests/test-openclaw-pairing-state.sh <sandbox-name> --label pre-recovery
./lib/map-openclaw-cli-approval-target.sh <sandbox-name> --format text
```

If the mapper reports that it is safe to apply, use the helper rather than
approving requests manually:

```bash
./lib/apply-openclaw-cli-approval.sh <sandbox-name> --format text
```

Then verify that the TUI connects and capture a second snapshot for comparison:

```bash
./tests/test-openclaw-pairing-state.sh <sandbox-name> --label post-recovery
nemoclaw <sandbox-name> connect
openclaw tui
```

If the helper refuses to act, stop and inspect the pairing-state snapshot
instead of approving arbitrary requests. For the detailed background and known
failure mode, see the RCA in `docs/rca/2026-04-04-nemoclaw-374a847-regression.md`.

## Web UI returns no response or `openclaw agent` times out

Start by checking whether inference is healthy through the OpenShell gateway:

```bash
openshell inference get
./tests/test-openshell-gateway-inference.sh <sandbox-name>
```

If needed during debugging, retry with a longer probe timeout:

```bash
./tests/test-openshell-gateway-inference.sh <sandbox-name> --timeout 120
```

Then check whether agent turns are falling back to the embedded path:

```bash
openclaw agent --agent main --json -m "Reply with exactly: pong"
```

If the output mentions `falling back to embedded`, treat the issue as a pairing
or gateway-path problem before treating it as a pure model-speed problem. In
this repository's RCA, pairing failure forced the embedded path, and that path
timed out around 20 seconds on Jetson Orin.

If gateway probing succeeds and pairing is healthy, compare the current timeout
against the repository ADR baseline in `docs/adr/0001-inference-timeout.md`.
This checkout expects a 120-second OpenShell inference timeout on Jetson Orin.
