# Container Identity, State, and What Happens When You Reboot

## Introduction

When you run software inside containers, one of the most important things to
understand is *where state lives* and *what survives a restart*. This document
explains those concepts, using a real-world example to make them concrete. The
example involves a specific AI development stack (NemoClaw on NVIDIA Jetson
hardware), but the principles apply to any containerized application.

---

## What Is a Container?

A container is a lightweight, isolated environment for running software. Think
of it like a shipping container on a cargo ship: the container has everything
the application needs packed inside it, and it can run the same way on any
ship (any host machine) that supports it.

Containers are created from *images* — read-only templates that define what's
inside. When you start a container from an image, the container gets its own
writable layer on top. Anything the application writes goes into that writable
layer.

Here is the critical part: **when a container is deleted, its writable layer
is gone**. The original image is untouched, but any data the container wrote
is lost — unless that data was stored somewhere that persists independently of
the container.

---

## What Is a Volume?

A *volume* is persistent storage that exists outside the container's own
writable layer. You attach a volume to a container at startup, and the
container reads and writes data to it. When the container stops or is deleted,
the volume remains. When you start a new container and attach the same volume,
all that data is still there.

Volumes are how containerized applications survive restarts.

```
Without a volume:
  Container A writes data → Container A is deleted → data is gone

With a volume:
  Container A writes to volume → Container A stops → volume persists
  Container B starts with same volume → data is still there
```

---

## What Are TLS Certificates and Why Do They Matter?

TLS (Transport Layer Security) is the technology behind the padlock you see in
your browser's address bar. It does two things: it encrypts the connection so
no one can intercept it, and it *verifies identity* — it proves that the server
you are talking to is actually who it claims to be.

TLS uses *certificates*, which are essentially signed identity documents. A
certificate authority (CA) signs certificates for other parties. When two
parties want to talk securely, each presents its certificate, and the other
side checks whether it was signed by a CA it trusts.

The important implication: **if two services are running with certificates
signed by different CAs, or if one side regenerates its certificate, they will
refuse to talk to each other**. This is by design — it prevents impersonation.
But it also means that if certificate state is not preserved correctly across
restarts, two services that previously trusted each other may suddenly reject
each other.

---

## A Container Running Another Container Scheduler

This is where things get interesting. Some containers don't just run a single
application — they run a *container scheduler* (like Kubernetes or its
lightweight variant, k3s). That scheduler then manages its own set of
containers, called *pods*.

```
Host machine
└── Docker (container runtime)
    └── gateway-container (runs k3s)
        ├── control-plane pod
        └── sandbox pod
```

From the host's perspective, this looks confusing: running `docker ps` shows
containers that Docker itself didn't directly create — k3s created them by
talking to Docker's API. They show up with names like `k8s_coredns_...` or
`k8s_metrics-server_...`.

**These k8s containers are normal and expected.** They are k3s's infrastructure
pods, equivalent to the operating system services of the mini-cluster running
inside the gateway container.

---

## What Survives a Clean Stop and Start?

Let's trace exactly what happens when you stop and restart the gateway
container cleanly.

**On stop:**
```
docker stop gateway-container
  → k3s receives shutdown signal
  → k3s stops all pods gracefully
  → all k8s_* containers on the host stop
  → gateway-container stops
  → the volume (k3s state, certificates, pod definitions) is untouched
```

**On start:**
```
docker start gateway-container
  → k3s starts, reads all state from the volume
  → k3s reschedules pods using the saved definitions
  → pods start with the same certificates as before
  → services pick up exactly where they left off
```

Because the volume is the source of truth, **a clean stop and start should be
invisible to the application layer**. Everything has the same identity it had
before — *provided the container image itself is not regenerating shared
secrets on startup*.

---

## What Goes Wrong: The Regenerated Secret Problem

Here is where an application-level bug can undermine what would otherwise be a
clean restart. Even if the volume is intact and k3s loads all state correctly,
a container that regenerates a shared secret on every start will cause
everything to break — because one side of a connection picks up the new secret
while the other side still has the old one.

This is distinct from a TLS certificate problem. TLS certificates are stored in
the volume and survive restarts correctly. The issue is with a separate
*shared authentication secret* used by a custom handshake protocol, which is
regenerated unconditionally by the container's startup script.

```
Reboot occurs
  → gateway container starts
  → entrypoint generates a NEW random SSH_HANDSHAKE_SECRET
  → control plane pod (openshell-0) picks up the new secret
  → sandbox pod (da-claw) retains the OLD secret from onboarding
  → control plane and sandbox disagree on the secret
  → every connection attempt: "handshake verification failed"
```

The volume is fine. The TLS certificates are fine. The failure is entirely in
the mismatched application-level secret.

---

## What Made This Hard to Diagnose

Several things made this failure mode non-obvious:

**The gateway reports "ready."** `openshell status` returns success because the
gateway container is up and k3s's API is responding. The secret mismatch is at
the application layer, not the infrastructure layer.

**The sandbox reports "Ready."** k3s considers the sandbox pod healthy — it's
running, its health checks pass. The mismatch is invisible to k3s.

**The error message is cryptic.** `kex_exchange_identification: Connection
closed by remote host` is a low-level SSH error. It doesn't say "secret
mismatch."

**The real message is buried in pod logs.** `SSH connection: handshake
verification failed` only appears inside the sandbox pod logs, which require
running a command inside the gateway container to see:

```bash
docker exec openshell-cluster-nemoclaw kubectl logs -n openshell da-claw
```

**The obvious explanations were all wrong.** Disk pressure, TLS certificate
regeneration, clock skew, and race conditions were all investigated and ruled
out before the actual cause — the entrypoint regenerating the secret — was
found by directly comparing the environment variables of the two pods:

```bash
# These two values were different on every restart:
docker exec openshell-cluster-nemoclaw kubectl exec -n openshell openshell-0 -- \
  printenv OPENSHELL_SSH_HANDSHAKE_SECRET

docker exec openshell-cluster-nemoclaw kubectl get pod -n openshell da-claw \
  -o jsonpath='{.spec.containers[0].env[?(@.name=="OPENSHELL_SSH_HANDSHAKE_SECRET")].value}'
```

---

## The Real-World Example

> **Note:** The following describes a specific system (NemoClaw, an AI agent
> sandbox from NVIDIA, running on a Jetson AGX Thor developer board). It is
> included as a concrete illustration of the principles above, not as general
> guidance for all systems.

In this setup, the OpenShell gateway container runs k3s. k3s manages two pods:
`openshell-0` (the control plane) and `da-claw` (the AI agent sandbox).

The gateway container's startup script (`cluster-entrypoint.sh`) generates a
fresh random `SSH_HANDSHAKE_SECRET` on every container start using
`/dev/urandom`. This secret is injected into the HelmChart that configures
`openshell-0`. But `da-claw` is a Kubernetes Sandbox CRD whose pod spec is
managed by a separate operator — the operator does not update the secret on
restart, so `da-claw` always starts with the secret from the last time
`nemoclaw onboard` was run.

After every reboot, `openshell-0` and `da-claw` disagreed on the secret.
Every connection was rejected. The only recovery was a full re-onboard, which
regenerated both sides from scratch.

**The fix** is in the patched cluster image (`Dockerfile.openshell-cluster-legacy`).
The entrypoint is modified to save the generated secret to the k3s persistent
volume on first start, and reload it from there on subsequent starts. Since the
volume survives stop/start cycles, both pods always share the same secret and
reboots work cleanly.

See `docs/fix-handshake-secret.md` for the complete technical description of
the bug and fix.

---

## Key Takeaways

**1. Volumes are the source of truth.** A container can be stopped, deleted,
and recreated, and if it uses a volume, all of its state is preserved.

**2. A clean stop/start should preserve identity** — but only if the container
image doesn't regenerate shared secrets on startup. If it does, the volume
being intact is not enough.

**3. Application-level secrets are not the same as TLS certificates.** TLS
state (stored in the volume) survived restarts correctly in this case. The
failure was in a separate shared secret managed entirely outside the volume.

**4. "Ready" does not mean "consistent."** Infrastructure health checks verify
that services are responding, not that their shared secrets match. A system
can report fully healthy while being in an internally inconsistent state.

**5. Compare environment variables directly when handshakes fail.** When two
pods should share a secret but one is rejecting the other's connections, the
fastest diagnostic is to read the secret from each pod's environment and
compare them directly.

**6. Fixes belong in the image, not the restart script.** Attempting to patch
the Kubernetes Sandbox CRD from outside after each restart doesn't work —
the operator reconciles the CRD back immediately. The only reliable fix is
making the container produce the same secret on every start.

---

## Summary Diagram

```
NORMAL REBOOT (with patched image)

  docker stop → volume preserved (including secret file)
  docker start → entrypoint loads secret from volume
             → openshell-0 gets same secret as before
             → da-claw starts with same secret
             → handshake succeeds → connect works ✓


FAILED REBOOT (unpatched image)

  docker start → entrypoint generates NEW random secret
             → openshell-0 gets new secret
             → da-claw still has old secret from onboarding
             → handshake rejected → connect fails ✗

  Fix: patch the image to persist the secret to the volume
```