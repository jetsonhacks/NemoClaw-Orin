# ADR 0001: Set OpenShell inference timeout to 120s for Jetson Orin

**Status:** Accepted
**Date:** 2026-04-05
**Deciders:** Jim
**RCA reference:** [docs/rca/2026-04-04-nemoclaw-374a847-regression.md](../rca/2026-04-04-nemoclaw-374a847-regression.md)

---

## Context

During investigation of the April 4, 2026 regression (NemoClaw commit 374a847),
the assistant was found to return no content after receiving a message via the
Web UI. Measurement on the Jetson AGX Orin with `gemma4:e4b` showed:

- Inference latency for a minimal payload: ~13s (cold load)
- Inference latency for a realistic agent turn (10,166 prompt tokens): ~30s
- openclaw per-turn overhead (assembly, tool injection, streaming): ~16s
- **Total end-to-end latency per turn: ~46s**

The OpenShell managed inference route defaults to a **60s timeout**. This is
nominally sufficient (46s < 60s), but leaves only 14s headroom — one slow
turn, a context growth, or a model reload would push it over.

OpenShell's architecture docs describe `inference.local` as a sandbox-local
managed route handled by the sandbox proxy and embedded router, not as a
request path that traverses the gateway at inference time. This ADR therefore
uses "managed inference timeout" deliberately. The measured result is still the
same: `openshell inference set --timeout` changes the effective timeout budget
for the route used by this deployment.

When the CLI device is not paired (as in the concurrent TUI regression), the
agent falls back to an **embedded runner** with a hardcoded ~20s timeout. That
path fails unconditionally on this hardware for any realistic turn. The two
issues are coupled: pairing failure causes inference failure.

The `openclaw.json` inside the running container is Landlock read-only.
`openclaw config set` is rejected at runtime. The only runtime-configurable
lever is `openshell inference set --timeout`, which is a host-side OpenShell
CLI command that persists in the OpenShell gateway config across gateway
restarts (but not across full gateway teardown/recreate during onboarding).

---

## Decision

Set `INFERENCE_TIMEOUT_SECONDS=120` (2 minutes) as the repository default for
this Jetson Orin deployment. Apply it as a post-step in both:

- `onboard-nemoclaw.sh` — after `ensure_inference_ready` checks or restores
  the active inference selection when possible
- `recover-sandbox.sh` — as part of `finalize_recovery`, the shared success
  path called after all three recovery outcomes

The value is overridable via the environment variable `INFERENCE_TIMEOUT_SECONDS`
without changing script code.

The command applied is:

```bash
openshell inference set \
  --timeout "$INFERENCE_TIMEOUT_SECONDS" \
  --provider "$active_provider" \
  --model "$active_model" \
  --no-verify
```

Failure is non-fatal: the step warns and continues rather than failing the
whole onboard or recovery, since the assistant will still work (just with the
60s default) if this step fails.

---

## Alternatives considered

### 1. Keep the default 60s

The 60s default is _marginally_ sufficient when pairing is healthy. However:

- It assumes pairing never fails, but the concurrent TUI pairing regression
  documented in the RCA shows pairing is fragile after commit 2804b74
- 14s headroom is too thin: context grows over a session, workspace files
  expand, and any model reload during a turn will consume several seconds
- The embedded fallback (~20s, hardcoded) means any pairing disruption
  immediately causes inference failure regardless of the gateway timeout

**Rejected.** The default is not safe for this hardware.

### 2. Set timeout to 180s or higher

More headroom. The Ollama default keep-alive is 5 minutes; a full model
reload from scratch takes ~13s on this Orin. A turn at maximum context
(131K tokens) has not been measured but would take significantly longer
than 46s.

However, a very high timeout delays user feedback on genuine hangs. 120s
gives roughly 2.5× the current measured worst case, which is sufficient
headroom for context growth while still surfacing real failures in reasonable
time.

**Could revisit** if turns at larger context sizes are observed to timeout.
The `INFERENCE_TIMEOUT_SECONDS` override makes this easy to adjust without
a code change.

### 3. Reduce context size instead

The 23 tool schemas and 26K-char system prompt account for the bulk of the
prompt tokens. Reducing tool injection (e.g., only injecting tools relevant
to the current agent config) would reduce latency.

This is a larger upstream change that belongs in a separate ADR and upstream
PR. It is not a substitute for a correct timeout — even a slimmer context
needs a realistic timeout.

**Deferred.** Not in scope for this fix.

### 4. Encode the timeout in the Docker image build args

The `NEMOCLAW_INFERENCE_TIMEOUT_SECONDS` ARG could be added to the Dockerfile
and wired into `openclaw.json` at build time, making it image-baked rather
than applied post-start.

This is the right long-term home for the setting but requires an upstream
Dockerfile change in NVIDIA/NemoClaw. The `openshell inference set` approach
works today without upstream changes.

**Deferred** pending upstream discussion on issue #1118.

---

## Consequences

**Positive:**
- Eliminates the no-response symptom on Jetson Orin for typical turns
- Provides ~74s of headroom above the current measured worst case (~46s)
- Applied on every onboard and every recovery — no manual step required
- Overridable without code changes via `INFERENCE_TIMEOUT_SECONDS`
- Failure is non-fatal; a warning is printed and the session continues

**Negative / risks:**
- Genuine inference hangs will take up to 120s to surface rather than 60s
- The setting is lost on full gateway teardown (e.g., `openshell gateway stop`)
  and must be re-applied; onboard/recover scripts cover the expected paths
  but a manual `openshell gateway restart` between script runs would not
- 120s is not grounded in a worst-case context measurement; if turns at
  large context (>50K tokens) become common, this may need revisiting

**Upstream action needed:**
- Comment on NVIDIA/NemoClaw issue #1118 with the Jetson Orin latency data
  (~340 tok/s prompt processing, ~46s/turn at 10K tokens) and request that
  the default timeout be raised or made configurable via `openclaw.json`
- The embedded fallback timeout (~20s, hardcoded in openclaw dist) is the
  deeper issue: any pairing disruption will trigger it regardless of the
  gateway timeout setting. This is tracked in the RCA open questions.
