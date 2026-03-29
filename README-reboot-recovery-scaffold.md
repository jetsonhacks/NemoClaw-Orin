# Reboot recovery for existing NemoClaw sandboxes on Jetson

This document explains what we learned while bringing an existing NemoClaw sandbox back after a host reboot on Jetson.

It is written for coworkers and future maintainers, especially people who may not already have a detailed mental model of OpenShell, the sandbox, and the user-facing OpenClaw path.

The main lesson is simple:

After a reboot, the problem is not just “start the container again.”

Bringing the system back means restoring several layers that depend on one another:

1. the outer OpenShell gateway infrastructure has to come back
2. the sandbox has to become reachable again
3. the user-facing path into the sandbox has to be restored
4. the inner OpenClaw gateway has to be started in the correct execution context
5. the agent may still need to be re-paired or re-approved before it is healthy again

During debugging, we first suspected DNS and inference wiring. Those were useful clues, but they were not the whole answer.

The real issue turned out to be that the OpenShell SSH session into the sandbox is not just a transport detail. It is part of the working runtime environment. Some of our helper scripts were clearing pieces of that environment, which made recovery look broken even when the real user-facing path still worked.

Once the helpers were changed to behave like the real OpenShell SSH session, the system recovered successfully through the intended CLI approval path.

---

## What “bringing the system back up” actually means

When the machine reboots, several things have to line up again before a user can run:

```bash
nemoclaw <sandbox-name> connect
openclaw tui
```

From the outside, it may look like there is just one service to restart. In practice, there are multiple layers.

### The outer layer

The outer layer is the OpenShell gateway container and the small control-plane environment running inside it.

This outer layer is responsible for:

* hosting the OpenShell gateway
* running the control plane that knows about sandboxes
* making it possible to reach a sandbox again after reboot
* mediating the user-facing path into that sandbox

If this layer is not healthy, there is no point trying to recover the inner OpenClaw process yet.

### The sandbox layer

Inside the outer system is the sandbox itself. This is the contained environment where the OpenClaw agent runs.

The sandbox is not just “a directory” or “a pod we can exec into.” It is an environment managed through the OpenShell substrate.

That matters because the user-facing path into the sandbox is not defined only by what appears when we use `kubectl exec`. The working path is the one OpenShell provides to the user through its SSH-based access path.

### The user-facing path

This was the key lesson from the debugging.

The underlying substrate that forms the gateway has an associated SSH environment that it uses to work with the agent inside the sandbox.

That SSH path is not just a shell prompt. It carries with it a curated runtime environment that the OpenClaw agent depends on. That includes things like proxy settings, CA bundle settings, and other environment values that make the agent’s outbound and internal communication work the way OpenShell expects.

So when we say we are “bringing the system back up,” what we really mean is:

* the outer gateway has to be healthy
* the sandbox has to be reachable
* the OpenShell-provided SSH session into the sandbox has to be working again
* the OpenClaw gateway inside the sandbox has to be started through that same path
* the agent’s pairing state has to be valid again

That is the real day-2 recovery problem.

---

## Where we started

At first, the reboot problem looked like a timing issue.

After reboot, the outer OpenShell environment was not always ready immediately. Waiting for the gateway container, the control plane, and the sandbox pod to settle did help.

The sequence:

```bash
./restart-nemoclaw.sh --debug
./lib/wait-for-openshell-cluster-stability.sh <sandbox-name> --debug
```

made the outer system much more stable before we attempted inner recovery.

That was a real improvement, but it did not fully solve the problem. The system could reach the point where the outer pieces were alive, but the agent inside the sandbox still did not behave as expected through our helpers.

That told us the remaining blocker was deeper than simple startup timing.

---

## The first strong suspicion: `inference.local`

The next clue pointed toward inference wiring.

We observed that:

* `openshell inference get` showed a valid configured provider and model
* the sandbox appeared to load an inference route bundle after reboot
* `/sandbox/.openclaw/openclaw.json` pointed at `https://inference.local/v1`
* `getent hosts inference.local` failed in the sandbox
* the Sandbox CRD did not inject `inference.local`
* probing the inference path timed out

That made it reasonable to suspect that the reboot problem was fundamentally about `inference.local` not being resolvable inside the sandbox.

We then tested a diagnostic `hostAlias` patch for `inference.local`.

That was useful because it proved two important things.

First, we could make the hostname resolve.

Second, hostname resolution by itself was not enough to restore the real working path.

This was the turning point. The DNS suspicion was not wrong as a clue, but it was incomplete as an explanation.

The actual usable path was tied to the sandbox proxy and the environment supplied by the OpenShell user-facing session.

So the story was no longer “the pod cannot resolve a hostname.” It became “the working runtime path is more than raw pod networking.”

---

## The big realization: the SSH session is part of the runtime contract

The decisive comparison was between two ways of entering the sandbox:

1. plain pod execution, such as `kubectl exec`
2. the raw OpenShell SSH session that the real user-facing workflow uses

These turned out not to be equivalent.

The plain pod environment did not contain the same environment variables as the OpenShell SSH path.

The SSH path included a curated execution environment with values such as proxy settings, CA settings, and OpenShell-specific markers. That environment was part of how the agent successfully communicated with the rest of the system.

This explained something important:

* on day-0, the user-facing OpenClaw path worked through the SSH session
* after reboot, raw SSH execution of `openclaw agent --agent main --local ...` also worked

So the platform itself was not fundamentally broken after reboot.

The real user-facing path still existed.

That meant our remaining failures were likely being introduced by our own recovery helpers rather than by a total platform failure.

This was the central insight of the debugging effort:

> The OpenShell SSH session is not just a convenience wrapper. It is part of the working runtime contract between the gateway substrate and the agent inside the sandbox.

---

## The bug in our helpers

Once we understood that the SSH execution context mattered, the next problem became easier to see.

Several of our SSH-based helpers were explicitly clearing proxy-related environment before running commands.

That seemed harmless at first. In many debugging situations, simplifying the environment can make behavior easier to reason about.

But here it did exactly the wrong thing.

It stripped away part of the environment that the working OpenShell path depended on.

As a result, helpers reported failures that were not really platform failures. They were failures inside an artificially broken session created by the helper itself.

This created false negatives.

In practice, that meant we sometimes concluded, “the recovered system still cannot use inference” or “the user-facing path is still unhealthy,” when the raw SSH path showed that the real system was in fact working.

That was the most important bug we fixed.

---

## Another real bug: starting the inner gateway through SSH

There was also a separate bug in the helper that starts the inner OpenClaw gateway through the SSH path.

Two specific issues showed up there.

The first was that `ensure_forward` had been wrapped inside a capture helper in a way that caused it to hang.

The second was that stale-process cleanup matched process command lines too broadly. In some cases, it could kill its own shell because the shell’s command line itself contained the text `openclaw gateway`.

That meant recovery could fail even when the high-level approach was correct.

The fixes were straightforward once identified:

* run the port-forward setup directly
* tighten stale-process matching
* skip the current shell and its parent process
* preserve the native SSH session environment instead of clearing it

With those changes in place, the helper behaved much more like the real user-facing path it was supposed to represent.

---

## What recovery looks like now

Once the outer recovery was stabilized, the helper environment was fixed, and the SSH gateway-start logic was corrected, the day-2 recovery story became much clearer.

Bringing the system back now means two different kinds of recovery.

### First, outer recovery

The outer OpenShell infrastructure has to be restored until it is stable enough to continue.

That includes:

* loading the OpenShell environment
* ensuring the gateway container is running
* selecting the intended gateway
* waiting for the gateway API to become ready
* waiting for the control plane pod to become ready
* waiting for the sandbox pod to become ready
* optionally waiting for cluster churn to settle

This is the job of:

* `restart-nemoclaw.sh`
* `lib/wait-for-openshell-cluster-stability.sh`

### Then, inner recovery

Once the outer system is stable, the sandbox’s user-facing path has to be restored.

That means:

* reconciling the sandbox SSH handshake state if it drifted
* starting the inner OpenClaw gateway through the OpenShell SSH path
* inspecting the durable device and pairing state inside the sandbox
* attempting to complete pairing through the CLI if possible
* using lower-level repair only if the CLI path is unavailable
* verifying that the final user-facing path is actually healthy

This is the job of:

* `recover-sandbox.sh`
* `lib/reconcile-sandbox-ssh-handshake.sh`
* `lib/start-openclaw-gateway-via-ssh.sh`
* `lib/inspect-openclaw-state.sh`
* `lib/map-openclaw-cli-approval-target.sh`
* `lib/apply-openclaw-cli-approval.sh`
* `lib/repair-openclaw-operator-pairing.sh`
* `lib/verify-openclaw-user-path.sh`

That separation turned out to be very important. It gave us a way to tell whether the outer platform was healthy before we started diagnosing the agent inside the sandbox.

---

## Why pairing is part of recovery

One subtle point is that the system can be partly back without being fully usable.

For example, after reboot and after the inner gateway starts, the listener may be up, but the agent may still be waiting for pairing approval.

That is why recovery is not complete just because a process is listening on a port.

The system is only really back when the user-facing path is healthy again.

That is why the recovery flow includes inspection of device state and pairing state, not just process startup.

---

## Why the CLI approval path is preferred

When pairing needs to be restored, the preferred path is to use the OpenClaw CLI approval flow.

That is the more natural recovery path because it uses the intended interface of the system rather than directly mutating internal state files.

The recovery helpers now try to:

1. inspect the local durable device state
2. inspect the CLI-visible pending requests
3. match the sandbox’s device identity to exactly one CLI request when that can be done safely
4. apply CLI approval through the user-facing path

If that succeeds, we have restored the system in a way that stays aligned with the intended OpenClaw pairing model.

That is the best outcome, and it is now the preferred successful recovery path.

### Why lower-level repair still exists

There is still a lower-level fallback that promotes pending pairing state mechanically.

That path remains useful when the CLI path is unavailable or cannot be matched safely.

But it is no longer the main story of the system.

The better mental model for maintainers is:

* first try to recover through the same user-facing mechanisms the system expects
* only fall back to lower-level repair when the intended path is unavailable

---

## The validated successful sequence

The sequence that ultimately worked was:

```bash
./restart-nemoclaw.sh --debug
./lib/wait-for-openshell-cluster-stability.sh <sandbox-name> --debug
./recover-sandbox.sh <sandbox-name> --skip-outer-restart --debug
```

After the helper fixes:

* the inner OpenClaw gateway started successfully
* the listener came up on `127.0.0.1:18789`
* verification correctly reported that pairing was still required when appropriate
* the CLI approval path succeeded
* final verification reported a healthy user-facing path
* the successful recovery path was `cli`

That was the point where the debugging story closed.

---

## What we learned

The final understanding is more precise than the story we started with.

It is **not** enough to say:

* the cluster needed more time
* or DNS for `inference.local` was broken

Those were parts of the path, but not the full answer.

What we actually learned is this:

* the outer OpenShell infrastructure must settle before inner recovery can succeed
* the sandbox’s real user-facing path is defined by the OpenShell SSH session, not merely by raw pod execution
* that SSH session carries environment needed by the agent inside the sandbox
* our helpers had drifted away from that real execution context by clearing environment they should have preserved
* once the helpers were corrected, the platform recovered through the intended CLI pairing flow

That is the important mental model for future debugging.

---

## Guidance for future maintainers

When working on reboot recovery, start with the simplest question:

**Does the real OpenShell SSH path into the sandbox work?**

That question is more valuable than asking whether some command works under `kubectl exec`, because the user-facing system depends on the SSH-mediated path.

Also keep these principles in mind:

### Keep outer and inner recovery separate

If the outer infrastructure is not healthy yet, inner debugging will only create noise.

### Treat the SSH session as part of the platform

Do not treat it as a disposable shell wrapper. It carries part of the runtime contract.

### Be cautious about “sanitizing” environment

In this debugging pass, clearing environment made the helpers less accurate, not more correct.

### Prefer the intended repair path

When possible, recover pairing through the CLI approval flow rather than by directly rewriting lower-level state.

### Distinguish facts from suspicions

The `inference.local` investigation was useful, but it should remain described as an intermediate hypothesis, not the final root cause.

---

## Bottom line

Bringing NemoClaw back after reboot is really the work of reconnecting layers.

The outer gateway substrate has to come back.

The sandbox has to become reachable again through the OpenShell-managed path.

The OpenShell SSH environment has to be treated as the real working context for the agent.

The inner OpenClaw gateway has to be started through that path.

And finally, the agent has to be re-approved if pairing is still pending.

Once we aligned our helpers with that reality, reboot recovery worked.

That is the current, evidence-based story of day-2 recovery for existing NemoClaw sandboxes on Jetson.
