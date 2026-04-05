---
name: nemoclaw-debug-inference-path
description: Diagnoses empty responses, inference timeouts, and gateway-versus-embedded execution path problems in this repository's Jetson NemoClaw workflow. Use when the web UI returns no content, when `openclaw agent` times out, or when validating the OpenShell inference route after onboard or recovery.
---

# NemoClaw Debug Inference Path

Diagnoses empty responses, inference timeouts, and gateway-versus-embedded execution path problems in this repository's Jetson-focused NemoClaw workflow.

Use this skill when:

- the web UI accepts a message but returns no assistant content
- `openclaw agent` times out or reports fallback to embedded mode
- you need to verify whether inference is flowing through the OpenShell gateway
- you want to validate that the 120-second OpenShell timeout is in effect after onboard or recovery

## Repository Sources

Start with the repo-local investigation and decision records:

- `docs/rca/2026-04-04-nemoclaw-374a847-regression.md`
- `docs/adr/0001-inference-timeout.md`
- `tests/test-openshell-gateway-inference.sh`
- `tests/test-openclaw-pairing-state.sh`
- `lib/map-openclaw-cli-approval-target.sh`
- `lib/apply-openclaw-cli-approval.sh`

## What This Skill Helps Distinguish

### Healthy gateway inference path

Typical indicators:

- `openshell inference get` shows the expected active provider and model
- `tests/test-openshell-gateway-inference.sh` returns HTTP 200
- `openclaw agent` does not mention embedded fallback

### Pairing-induced embedded fallback

Typical indicators:

- `openclaw agent` reports gateway connection failure
- output contains `Gateway agent failed; falling back to embedded`
- embedded mode then times out around 20 seconds on realistic prompts

If this appears, switch immediately to the local pairing workflow and recover pairing before spending time on model latency.

### True gateway timeout or latency issue

Typical indicators:

- gateway inference probe works, but realistic turns are still slow
- timeout behavior improves after `openshell inference set --timeout 120`
- failures correlate with larger prompt/context sizes rather than pairing state

## Step 1: Confirm the Active OpenShell Inference Route

Start on the host:

```bash
openshell inference get
```

Check:

- active provider
- active model
- whether the expected timeout is present after onboard or recovery

This repository's default decision is documented in `docs/adr/0001-inference-timeout.md`: Jetson Orin should use a 120-second OpenShell inference timeout unless overridden.

## Step 2: Probe the Gateway Path Directly

Use the repo probe to test `https://inference.local/v1/chat/completions` from inside the sandbox through the user-facing SSH path:

```bash
./tests/test-openshell-gateway-inference.sh <sandbox-name>
```

If needed, use a longer probe timeout while investigating:

```bash
./tests/test-openshell-gateway-inference.sh <sandbox-name> --timeout 120
```

Interpret the result:

- HTTP 200 with the expected text means the gateway inference route is functioning
- curl timeout or non-200 status points to a gateway-route, provider, or timeout problem
- a passing minimal probe does not rule out realistic-turn latency issues

## Step 3: Check Whether Agent Turns Are Falling Back to Embedded

Run a simple agent test:

```bash
openclaw agent --agent main --json -m "Reply with exactly: pong"
```

Look for these signatures:

- `Gateway agent failed; falling back to embedded`
- `[agent/embedded] error=LLM request timed out`

If you see them, do not treat the issue as a pure model-speed problem yet. This repo's RCA shows that pairing failure can force the embedded path, and that embedded path times out around 20 seconds on this hardware.

## Step 4: If Embedded Fallback Appears, Recover Pairing First

Use the local pairing workflow:

```bash
./tests/test-openclaw-pairing-state.sh <sandbox-name> --label pre-inference-debug
./lib/map-openclaw-cli-approval-target.sh <sandbox-name> --format text
./lib/apply-openclaw-cli-approval.sh <sandbox-name> --format text
```

Then re-run:

```bash
openclaw agent --agent main --json -m "Reply with exactly: pong"
```

Only continue with latency tuning after the gateway path is healthy.

## Step 5: Validate Timeout Headroom

For Jetson Orin, this repo's accepted baseline is:

- minimal cold-load request: about 13 seconds
- realistic agent turn: about 46 seconds end-to-end
- OpenShell timeout target: 120 seconds

If current behavior suggests the timeout is still too low, verify or re-apply the host-side OpenShell setting:

```bash
openshell inference set \
  --timeout 120 \
  --provider "<active-provider>" \
  --model "<active-model>" \
  --no-verify
```

This setting is host-side and survives ordinary gateway restarts, but it is not guaranteed to survive full gateway teardown/recreate.

## Step 6: Separate Minimal-Path Success from Realistic-Turn Failure

A passing gateway probe only proves the minimal path works.

If:

- the minimal probe succeeds
- pairing is healthy
- realistic agent turns are still slow or empty

then the remaining issue is likely one of:

- prompt/context size
- model throughput on Jetson Orin
- OpenClaw per-turn overhead
- a separate upstream empty-response issue

Use the RCA and ADR as the baseline interpretation before changing scripts.

## Command Summary

```bash
openshell inference get
./tests/test-openshell-gateway-inference.sh <sandbox-name>
./tests/test-openshell-gateway-inference.sh <sandbox-name> --timeout 120
openclaw agent --agent main --json -m "Reply with exactly: pong"
./tests/test-openclaw-pairing-state.sh <sandbox-name> --label pre-inference-debug
./lib/map-openclaw-cli-approval-target.sh <sandbox-name> --format text
./lib/apply-openclaw-cli-approval.sh <sandbox-name> --format text
```

## Related Files

- `docs/adr/0001-inference-timeout.md`
- `docs/rca/2026-04-04-nemoclaw-374a847-regression.md`
- `docs/troubleshooting.md`
- `docs/scripts.md`
- `.agents/skills/nemoclaw-debug-pairing/SKILL.md`
