# Fix: SSH Handshake Secret Regeneration on Restart

## Summary

After every gateway container restart, `nemoclaw da-claw connect` fails with:

```
kex_exchange_identification: Connection closed by remote host
  Command failed (exit 255): openshell sandbox connect 'da-claw'
```

The root cause is an upstream bug in OpenShell's `cluster-entrypoint.sh`: a
new random `SSH_HANDSHAKE_SECRET` is generated on every container start. The
control plane pod (`openshell-0`) picks up the new secret, but the sandbox pod
(`da-claw`) retains the secret from the last `nemoclaw onboard` run. Every
restart leaves them with mismatched secrets, causing every connection to be
rejected.

The fix patches `cluster-entrypoint.sh` in the local cluster image to persist
the secret to the k3s volume on first start and reload it on subsequent starts.

---

## Background: The NSSH1 Handshake

OpenShell uses a custom SSH handshake protocol called NSSH1. Before establishing
an SSH connection, the gateway (`openshell-0`) and the sandbox (`da-claw`)
exchange an HMAC-based challenge using a shared secret. If the secrets don't
match, the handshake is rejected and the connection is dropped immediately.

This shared secret is separate from the TLS certificates used by k3s. TLS state
is stored in the k3s volume and survives restarts correctly. The NSSH1 secret is
not stored anywhere persistent in the upstream image — it is regenerated from
`/dev/urandom` on every container start.

---

## Root Cause

`cluster-entrypoint.sh` contains this line (approximately line 408):

```sh
SSH_HANDSHAKE_SECRET="${SSH_HANDSHAKE_SECRET:-$(head -c 32 /dev/urandom | od -A n -t x1 | tr -d ' \n')}"
```

This generates a fresh random secret unconditionally on every container start
(unless `SSH_HANDSHAKE_SECRET` is already set in the environment, which it
isn't in normal operation). The secret is then injected into the HelmChart that
configures `openshell-0`.

`da-claw` is a Kubernetes Sandbox CRD managed by the `agent-sandbox-controller`
operator. The operator sets `OPENSHELL_SSH_HANDSHAKE_SECRET` in the pod spec
during `nemoclaw onboard` and does not update it on subsequent gateway restarts.

After a restart:

```
openshell-0 env:  OPENSHELL_SSH_HANDSHAKE_SECRET = <new value>
da-claw pod spec: OPENSHELL_SSH_HANDSHAKE_SECRET = <original value from onboard>
```

Every connection attempt fails. The operator reconciles the Sandbox CRD
continuously and overwrites any external patch attempt immediately, so the
mismatch cannot be resolved from outside.

---

## Confirming the Bug

After a restart, compare the secrets directly:

```bash
# Secret in the control plane pod
docker exec openshell-cluster-nemoclaw kubectl exec -n openshell openshell-0 -- \
  printenv OPENSHELL_SSH_HANDSHAKE_SECRET

# Secret in the sandbox pod spec
docker exec openshell-cluster-nemoclaw kubectl get pod -n openshell da-claw \
  -o jsonpath='{.spec.containers[0].env[?(@.name=="OPENSHELL_SSH_HANDSHAKE_SECRET")].value}'
```

If the two values differ, this bug is the cause. The sandbox pod logs will also
show the rejection:

```bash
docker exec openshell-cluster-nemoclaw kubectl logs -n openshell da-claw | grep handshake
# WARN openshell_sandbox::ssh: SSH connection: handshake verification failed
```

And the control plane logs will show the failure from its side:

```bash
docker exec openshell-cluster-nemoclaw kubectl logs -n openshell openshell-0 | grep -i handshake
# WARN openshell_server::ssh_tunnel: SSH tunnel failure error=sandbox handshake rejected
```

---

## The Fix

The fix is in `Dockerfile.openshell-cluster-legacy`, applied at image build
time by `patch-entrypoint.sh`. It rewrites the relevant section of
`cluster-entrypoint.sh` to:

1. On first start: generate the secret as before, then save it to
   `/var/lib/rancher/k3s/openshell-handshake-secret` inside the k3s volume.
2. On subsequent starts: load the secret from that file instead of generating
   a new one.

The k3s volume (`openshell-cluster-nemoclaw`) is mounted at
`/var/lib/rancher/k3s` inside the container and survives stop/start cycles,
so the secret file persists across reboots.

**Patched behavior:**

```sh
SECRET_FILE="/var/lib/rancher/k3s/openshell-handshake-secret"
if [ -f "$SECRET_FILE" ]; then
    SSH_HANDSHAKE_SECRET="$(cat "$SECRET_FILE")"
    echo "Loaded persisted SSH handshake secret"
else
    SSH_HANDSHAKE_SECRET="$(head -c 32 /dev/urandom | od -A n -t x1 | tr -d ' \n')"
    echo "Generated new SSH handshake secret"
fi
# ... inject into HelmChart ...
mkdir -p "$(dirname "$SECRET_FILE")"
printf '%s' "$SSH_HANDSHAKE_SECRET" > "$SECRET_FILE"
chmod 600 "$SECRET_FILE"
```

After this fix, both pods always share the same secret they had when first
onboarded, and reboots work without any manual intervention.

---

## Applying the Fix

The fix requires rebuilding the local cluster image and re-onboarding once to
initialize the secret file.

```bash
# Rebuild the patched image
source ~/.config/openshell/jetson-orin.env
docker build \
  --build-arg CLUSTER_VERSION=0.0.13 \
  -t "$OPENSHELL_CLUSTER_IMAGE" \
  -f ~/NemoClaw-Orin/Dockerfile.openshell-cluster-legacy \
  ~/NemoClaw-Orin/

# Re-onboard once to initialize the secret file on first start
./onboard-nemoclaw.sh
```

After `nemoclaw da-claw connect` succeeds, verify the secret file exists in the
volume:

```bash
sudo cat /var/lib/docker/volumes/openshell-cluster-nemoclaw/_data/openshell-handshake-secret
```

It should contain a 64-character hex string. From this point forward, stop/start
cycles reload this file and both pods always agree on the secret.

---

## Verifying the Fix

```bash
# Simulate a reboot
docker stop openshell-cluster-nemoclaw
docker start openshell-cluster-nemoclaw
openshell gateway select nemoclaw

# Wait for pods to come up (or use restart-nemoclaw.sh)
sleep 60

# Should connect cleanly
nemoclaw da-claw connect
```

After connecting, confirm da-claw has 0 restarts:

```bash
docker exec openshell-cluster-nemoclaw kubectl get pods -n openshell
# da-claw   1/1   Running   0   ...
```

0 restarts means da-claw connected to openshell-0 on the first attempt — the
secrets matched.

---

## Upstream Status

This is a bug in OpenShell's `cluster-entrypoint.sh`. The fix should be applied
upstream so that the secret is persisted to the k3s volume by default. Until
that happens, the local patch in `Dockerfile.openshell-cluster-legacy` and
`patch-entrypoint.sh` is the workaround.

When upgrading OpenShell to a new version, verify that the `patch-entrypoint.sh`
guard conditions still match — the script checks for the exact lines it expects
to patch and exits with an error if they have changed, preventing a silent
no-op.

```bash
# Check if the patch still applies cleanly against a new version
docker run --rm --entrypoint sh ghcr.io/nvidia/openshell/cluster:<new-version> \
  -c 'grep -n "SSH_HANDSHAKE_SECRET\|urandom" /usr/local/bin/cluster-entrypoint.sh'
```

If the output lines match what `patch-entrypoint.sh` expects, the patch is
still valid. If they have changed, update `patch-entrypoint.sh` to match before
rebuilding.
