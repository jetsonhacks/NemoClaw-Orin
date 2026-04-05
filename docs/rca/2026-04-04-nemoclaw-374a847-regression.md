# RCA: NemoClaw regression after commit 2804b74 (merged April 1, 2026)

**Status:** TUI pairing root cause confirmed. Web UI empty-response cause strongly supported but not fully proven end-to-end from the original failing session. (Updated 2026-04-05)
**Investigated by:** Jim / Claude Code session (2026-04-04 through 2026-04-05)
**Upstream repo:** NVIDIA/NemoClaw
**Local repo:** NemoClaw-Orin (Jetson AGX Orin)
**NemoClaw commit at time of investigation:** 374a847

---

## Summary

Two separate regressions were introduced or exposed by the NemoClaw upstream
change at commit 2804b74 ("fix(security): harden gateway auth defaults and
restrict auto-pair #1217", merged April 1, 2026). A fresh onboard appeared
to succeed but the assistant was unreliable afterward:

1. `openclaw tui` immediately shows "Pairing required" and cannot connect.
2. The Web UI accepts a message but the assistant returns no content.

The TUI pairing regression has a confirmed root cause. The Web UI empty-response
regression has a strongly supported explanation, but the exact failure path from
the original session was not fully reproduced.

---

## Timeline

| Time (UTC) | Event |
|---|---|
| 2026-04-01 | Commit 2804b74 merged: adds auto-pair allowlist, hardens device auth defaults in Dockerfile |
| 2026-04-01 | Commit fcb0fae merged: patches onboard flow to set `NEMOCLAW_DISABLE_DEVICE_AUTH=1` in the staged Dockerfile at image build time |
| 2026-04-03 | Commit 1120c2b merged: forces `openai-completions` for Ollama onboard path (unrelated fix) |
| 2026-04-04 | Fresh onboard run on Jetson Orin. Completed normally, printed sandbox summary. |
| 2026-04-04 | `openclaw tui` fails with "Pairing required" immediately after onboard. |
| 2026-04-04 | Web UI sends "Hello there!", assistant entry appears, no response content returned. |
| 2026-04-04 | Investigation session begins. |

---

## Environment at time of investigation

- Hardware: NVIDIA Jetson AGX Orin
- NemoClaw commit: 374a847 (HEAD as of 2026-04-04)
- OpenShell version: 0.0.22 (cluster image `ghcr.io/nvidia/openshell/cluster:0.0.22`)
- OpenClaw version: 2026.3.11 (29dc654) — gateway reports update available: v2026.4.2
- Sandbox name: `da-claw`
- Model: `gemma4:e4b` via local Ollama
- Provider: `ollama-local`, `api: openai-completions`
- `NEMOCLAW_DISABLE_DEVICE_AUTH`: `1` (correctly patched by `fcb0fae` during onboard)
- `dangerouslyDisableDeviceAuth` in `openclaw.json`: `true`
- `allowInsecureAuth` in `openclaw.json`: `true`

---

## Regression 1: TUI pairing failure

### Symptom

Running `openclaw tui` after a successful onboard produces:

```
Pairing required. Run `openclaw devices list`, approve your request ID,
then reconnect.
```

### Investigation

`/tmp/auto-pair.log` inside the sandbox:

```
[auto-pair] rejected unknown client=cli mode=cli
[auto-pair] watcher timed out approvals=0
```

`/sandbox/.openclaw/devices/paired.json`: `{}`
`/sandbox/.openclaw/devices/pending.json`: one entry with `clientId: "cli"`, `clientMode: "cli"`

`/tmp/gateway.log` shows ~90 connections closed with `code=1008 reason=pairing required`,
all from the same device ID, before the webchat session connects successfully at 21:57:13.

### Root cause

OpenClaw itself owns the pairing model, pending approvals, and the user-facing
`Pairing required` error path. NemoClaw does not implement pairing from
scratch. Instead, it configures OpenClaw's gateway auth settings at image build
time and adds an entrypoint-side auto-pair helper intended to smooth the first
browser connection.

Commit 2804b74 added an allowlist to the auto-pair watcher in
`scripts/nemoclaw-start.sh`:

```python
ALLOWED_CLIENTS = {'openclaw-control-ui'}
ALLOWED_MODES   = {'webchat'}
```

The TUI sends `clientId: "cli"` and `clientMode: "cli"`. Neither matches the
allowlist. The auto-pair watcher logs a rejection and never approves it. The
watcher then times out (10-minute deadline) with `approvals=0`.

So the regression is best understood as an integration bug in NemoClaw's
OpenClaw pairing automation layer: the underlying pairing requirement is normal
OpenClaw behavior, but NemoClaw's allowlist only handled the browser client and
not the CLI/TUI client.

### Why `dangerouslyDisableDeviceAuth: true` does not help

`dangerouslyDisableDeviceAuth` is scoped to `gateway.controlUi` in
`openclaw.json`. It disables the device auth gate for the web control UI
path only. The TUI/CLI connection path enforces pairing independently.
Confirming evidence: the gateway logs `security warning: dangerous config
flags enabled` on startup, yet the TUI connections still fail with 1008.

### Relationship to fcb0fae

`fcb0fae` correctly patches the Dockerfile at onboard time to set
`NEMOCLAW_DISABLE_DEVICE_AUTH=1`, which sets `dangerouslyDisableDeviceAuth`
for the web UI. This was the right fix for web UI access. It does not address
TUI/CLI pairing, which goes through a separate gate.

This also clarifies the ownership boundary:

- OpenClaw owns device pairing and approval state
- NemoClaw owns the image-time auth configuration and the startup-time
  auto-pair integration
- The observed regression sits in NemoClaw's integration layer, not in
  OpenShell transport auth

### Upstream tracking

- Issue [#1310](https://github.com/NVIDIA/NemoClaw/issues/1310): open, high priority — direct report of this symptom
- PR [#690](https://github.com/NVIDIA/NemoClaw/pull/690): open — the right vehicle for extending `ALLOWED_CLIENTS` to include `"cli"`

### Workaround (manual, session-scoped)

```bash
# Run from the Jetson host after nemoclaw connect
./lib/apply-openclaw-cli-approval.sh da-claw --format text
```

This uses the existing `map-openclaw-cli-approval-target.sh` logic to find
the pending request by device ID and approve it via `openclaw devices approve`.
Must be repeated each time the TUI reconnects, since it does not survive
sandbox restarts.

---

## Regression 2: Web UI empty assistant response

> **Certainty note:** The explanation below is a strongly supported hypothesis.
> The exact failure path from the original "Hello there!" session was not
> reproduced — no inference log entry was found for that message, and the
> session conditions (pairing churn + first Web UI message) cannot be replayed
> identically. The hypothesis is supported by direct measurement of latency
> and timeout values, and by a successful reproduction of the timeout via
> `openclaw agent`. See Open question 2 for what remains uncertain.

### Symptom

A message sent via the Web UI (`openclaw-control-ui`) produces an assistant
entry with no content. No error is displayed. The UI appears to be waiting
or the response is silently discarded.

### Investigation

End-to-end inference probe (`tests/test-openshell-gateway-inference.sh`):

```
Result: PASS  (with --timeout 120)
HTTP:   200
Elapsed: ~13s (cold load)
```

Raw cold-load request (minimal payload, ~100 bytes):

```
Elapsed: 13s
HTTP: 200
Content: "pong"
```

`openclaw.json` inference API: `openai-completions` — H1 (cached
`openai-responses`) ruled out.

`ollama ps` immediately after probe: model loaded in GPU, 16 GB, 4-minute
keep-alive. Cold load is 13s — well within the 60s gateway timeout. H2
(model eviction / Jetson timeout) ruled out.

Agent path via embedded runner:

```
openclaw agent --agent main --json -m "Reply with exactly: pong"
```

Output:

```
gateway connect failed: GatewayClientRequestError: pairing required
Gateway agent failed; falling back to embedded
[agent/embedded] error=LLM request timed out.
durationMs: 19,899
stopReason: error
```

Realistic agent-sized payload (50K bytes, matching actual context):

```
Payload: 51,802 bytes (10,166 prompt tokens)
Elapsed: 29.9s
Finish:  stop
Content: "pong"
```

### Most likely cause

The agent builds a system prompt of ~26,400 characters plus 23 tool schemas
totalling ~18,700 characters — approximately 10,000 prompt tokens. On this
Jetson Orin with `gemma4:e4b`, a request at that context size takes ~30s of
inference plus ~16s of openclaw overhead (system prompt assembly, tool schema
injection, streaming) — approximately **46 seconds end-to-end**.

The OpenShell managed inference route defaults to a **60s timeout**. The 60s
default is marginally sufficient (46s < 60s), but leaves only 14s headroom.

> **Architecture correction (added 2026-04-04):** OpenShell's own architecture
> docs describe `inference.local` as a sandbox-local managed route handled by
> the sandbox proxy and embedded `openshell-router`, not a request path that
> traverses the OpenShell gateway at inference time. The measured timeout and
> latency findings below still hold, but "gateway path timeout" was too strong
> a claim. What is confirmed is that `openshell inference set --timeout`
> materially affects the managed inference route used by this deployment.

**However**, when the CLI device is not paired (Regression 1), `openclaw agent`
cannot complete its normal OpenClaw session path and falls back to an embedded
runner path. That embedded path appears not to use the same effective runtime
timeout budget as the managed OpenShell route configured by
`openshell inference set`. The embedded path uses a hardcoded internal limit of
approximately **20 seconds**.

20s embedded timeout < 46s actual latency → `LLM request timed out`.

The two regressions are coupled: pairing failure (Regression 1) causes the
inference timeout failure (Regression 2). The Web UI session was affected by
this same coupling — while the webchat client connects successfully, the
`openclaw-control-ui` session appears to hit the same embedded-fallback failure
mode for agent turns when the CLI device is unpaired, producing the empty
response.

The OpenShell inference timeout was raised to **120s** via:

```bash
openshell inference set --timeout 120 --provider ollama-local --model gemma4:e4b
```

After pairing the CLI device and restarting the session with the 120s timeout,
the agent returned a response with `stopReason: stop` in **46s** end-to-end.

### Contributing factors

- 23 tools injected with every request regardless of conversation content
- System prompt bootstraps workspace files (AGENTS.md, SOUL.md, TOOLS.md, etc.)
  totalling ~26K chars on every turn
- `gemma4:e4b` prompt-processing throughput on Jetson Orin: ~340 tokens/sec
  (10,166 tokens / 30s inference)
- openclaw overhead per turn: ~16s (assembly, injection, streaming)
- Total per-turn latency: ~46s
- Default OpenShell managed inference timeout (60s) leaves only 14s headroom
- Embedded fallback timeout (~20s) is hardcoded and not configurable at runtime;
  `openclaw.json` is Landlock read-only in the running container
- `openclaw config set agents.defaults.timeoutSeconds` is rejected at runtime
  for the same reason

### Upstream tracking

- Issue [#1118](https://github.com/NVIDIA/NemoClaw/issues/1118): open —
  router/timeout issues with local Ollama inference
- Issue [#1193](https://github.com/NVIDIA/NemoClaw/issues/1193): open —
  agent returns empty content when model generates tool calls instead of text
  (separate but related empty-response symptom)

---

## What was ruled out

| Hypothesis | Evidence against |
|---|---|
| Cached image with `openai-responses` API | `openclaw.json` shows `api: openai-completions`; `patchStagedDockerfile` in `onboard.js` patched it correctly |
| Ollama model eviction / first-load timeout | Cold load measured at 13s; managed inference timeout is 60s; model loaded correctly |
| OpenShell 0.0.22 routing regression | `inference.local` resolves and returns HTTP 200 from inside the sandbox |
| `dangerouslyDisableDeviceAuth` not set | Confirmed `true` in `openclaw.json` |

---

## Open questions

1. **Config write anomaly**: at startup (21:54:39) the gateway logged a SHA256
   mismatch on `openclaw.json` with "missing-meta-before-write". The backup
   differs from the current config only in the auth token field. The cause of
   this write is unknown. Could be `nemoclaw connect` rewriting the config on
   attach. Not believed to be related to either regression but warrants a
   follow-up look.

2. **Exact Web UI failure path**: the "Hello there!" message from the original
   report produced no inference log entry. It is unclear whether it hit the
   embedded path (timeout at 20s) or the normal managed inference path
   (timeout at 60s, which should have been sufficient). Could not reproduce the exact original Web UI
   failure in this session since the window of overlap with TUI pairing churn
   has passed.

3. **Embedded runner timeout value**: the ~20s figure is inferred from
   `durationMs: 19,899`. The actual configured timeout value and where it is
   set in the openclaw/nemoclaw source has not been located.

4. **Tool injection policy**: it is not confirmed whether the 23-tool system
   prompt is fixed per model or whether it varies by conversation state or
   agent configuration.

---

## Recommended next steps

### Implemented

- **TUI pairing (done, local workaround)**: `onboard-nemoclaw.sh` now calls
  `ensure_cli_pairing` after onboard, and `recover-sandbox.sh` now applies the
  same safe approval step on its successful recovery path. Both use
  `lib/apply-openclaw-cli-approval.sh` rather than approving arbitrary pending
  requests. See [docs/adr/0002-cli-pairing-auto-approval.md](../adr/0002-cli-pairing-auto-approval.md).

- **Inference timeout (done)**: `openshell inference set --timeout 120` is
  now applied automatically by `onboard-nemoclaw.sh` (`ensure_inference_timeout`)
  and `recover-sandbox.sh` (`finalize_recovery`) after every successful onboard
  or recovery. The value defaults to 120s and is overridable via
  `INFERENCE_TIMEOUT_SECONDS`. See [docs/adr/0001-inference-timeout.md](../adr/0001-inference-timeout.md).

### Upstream

- **TUI pairing**: contribute a fix to PR [#690](https://github.com/NVIDIA/NemoClaw/pull/690)
  adding `"cli"` to `ALLOWED_CLIENTS` in `scripts/nemoclaw-start.sh`, with
  evidence from this RCA.

- **Ownership clarification**: describe the bug upstream as a NemoClaw
  integration regression around OpenClaw pairing, not as an OpenShell auth
  failure. The pairing requirement itself is expected OpenClaw behavior; the
  faulty part is NemoClaw's incomplete auto-pair handling for non-browser
  clients.

- **Inference timeout**: comment on issue [#1118](https://github.com/NVIDIA/NemoClaw/issues/1118)
  with the Jetson Orin latency data (~340 tok/s at 10K token context,
  ~46s/turn end-to-end). The embedded fallback timeout (~20s, hardcoded) is
  the deeper risk — any pairing disruption triggers it regardless of the
  managed inference timeout setting.

---

## Commands used during investigation

```bash
# Gateway and sandbox health
openshell status
openshell sandbox list
openshell inference get

# Ollama model state
ollama ps
curl -s http://127.0.0.1:11434/api/tags

# Sandbox SSH (used for all commands below)
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o "ProxyCommand=openshell ssh-proxy --gateway-name nemoclaw --name da-claw" \
  sandbox@openshell-da-claw "<command>"

# Auto-pair log
cat /tmp/auto-pair.log

# Device state
openclaw devices list --json
cat /sandbox/.openclaw/devices/paired.json
cat /sandbox/.openclaw/devices/pending.json

# Gateway auth config
python3 -c "import json; d=json.load(open('/sandbox/.openclaw/openclaw.json')); print(json.dumps(d['gateway'], indent=2))"

# Gateway log
tail -150 /tmp/gateway.log

# End-to-end inference probe (with extended timeout)
GATEWAY_NAME=nemoclaw ./tests/test-openshell-gateway-inference.sh da-claw --timeout 120

# Cold-load timing (minimal payload)
# See investigation notes — 13s

# Agent path (reproduces the timeout)
openclaw agent --agent main --json -m "Reply with exactly: pong"

# Realistic payload timing (50K bytes / 10K tokens)
# See investigation notes — 29.9s
```
