---
name: nemoclaw-debug-pairing
description: Diagnoses and recovers recurring OpenClaw pairing failures in this repository's NemoClaw Jetson workflow. Use when `openclaw tui` says `Pairing required`, when the web UI returns empty responses that may be caused by gateway pairing fallback, or when validating the local CLI approval helpers.
---

# NemoClaw Debug Pairing

Diagnoses and recovers recurring OpenClaw pairing failures in this repository's Jetson-focused NemoClaw workflow.

Use this skill when:

- `openclaw tui` prints `Pairing required`
- the web UI connects but assistant turns come back empty or time out
- you need to tell whether a failure is caused by pairing, policy, or inference latency
- you want to validate or apply the local CLI approval helpers in `lib/`

## Repository Sources

Start with the repo-local sources that capture the known regression and the existing recovery helpers:

- `docs/rca/2026-04-04-nemoclaw-374a847-regression.md`
- `docs/adr/0001-inference-timeout.md`
- `docs/scripts.md`
- `lib/map-openclaw-cli-approval-target.sh`
- `lib/apply-openclaw-cli-approval.sh`
- `tests/test-openclaw-pairing-state.sh`

## What This Skill Helps Distinguish

### Pairing regression

Typical symptom:

```text
Pairing required. Run `openclaw devices list`, approve your request ID, then reconnect.
```

Common indicators:

- pending CLI device exists, but is not in `paired.json`
- auto-pair log rejects `client=cli mode=cli`
- gateway logs show repeated close `code=1008 reason=pairing required`

### Embedded fallback caused by pairing failure

Typical symptom:

- `openclaw agent` or web UI turns produce empty output or time out

Common indicators:

- gateway connection fails because pairing is required
- agent falls back to embedded mode
- embedded path times out around 20 seconds on large prompts

### Network policy problem

Typical symptom:

- request blocked in OpenShell TUI, often with a visible host/port approval prompt

If the failure is clearly an egress approval problem, switch to the policy and sandbox monitoring docs instead of continuing with pairing recovery.

## Step 1: Capture Current Pairing State

Collect a snapshot first so we can compare before and after recovery:

```bash
./tests/test-openclaw-pairing-state.sh <sandbox-name> --label pre-recovery
```

This captures:

- `verify-openclaw-user-path` output
- repo maintenance inspection output
- mapper output
- raw `device.json`, `paired.json`, and `pending.json`

## Step 2: Check Whether a Safe Approval Target Exists

Use the mapper first. It is the repository's safety gate for mechanical recovery.

```bash
./lib/map-openclaw-cli-approval-target.sh <sandbox-name> --format text
```

Interpret the result:

- `noop_already_paired`: pairing is not the current problem
- `safe_to_apply=true`: the helper found exactly one safe pending match
- `refuse_*`: stop and inspect before approving anything manually

## Step 3: Apply the Approval When Safe

If the mapper reports a safe approval target, use the repo helper instead of approving blindly by hand:

```bash
./lib/apply-openclaw-cli-approval.sh <sandbox-name> --format text
```

This is the preferred recovery action for the known CLI pairing regression documented in the RCA.

Important:

- the approval is a recovery action, not a durable upstream fix
- it may need to be repeated after reconnects or sandbox restarts

## Step 4: Verify That Pairing Actually Recovered

Re-run the snapshot and compare:

```bash
./tests/test-openclaw-pairing-state.sh <sandbox-name> --label post-recovery
diff -ru tmp/test-openclaw-pairing-state/<sandbox-name>/<older> tmp/test-openclaw-pairing-state/<sandbox-name>/<newer>
```

Then verify the user path directly:

```bash
nemoclaw <sandbox-name> connect
openclaw tui
```

Signs of success:

- the TUI connects without `Pairing required`
- the pending entry moves to paired state
- repeated `1008 pairing required` closures stop

## Step 5: If Responses Are Still Empty, Test for Embedded Fallback

Once pairing is healthy, distinguish latency from auth failure:

```bash
openclaw agent --agent main --json -m "Reply with exactly: pong"
```

Look for:

- `Gateway agent failed; falling back to embedded`
- `[agent/embedded] error=LLM request timed out`

If those appear, pairing may still be unhealthy or a prior session is still using the wrong path.

If pairing is fixed but latency remains high, use the inference timeout ADR and local inference probe:

```bash
./tests/test-openshell-gateway-inference.sh
```

## Step 6: Escalate Only When the Helper Refuses

If the mapper returns `refuse_*`, gather evidence before changing anything:

- inspect the latest snapshot under `tmp/test-openclaw-pairing-state/`
- review `docs/rca/2026-04-04-nemoclaw-374a847-regression.md`
- compare local pending and paired device records
- inspect gateway and auto-pair logs through the normal sandbox/user path

Do not auto-approve arbitrary requests if:

- there are multiple pending matches
- the local durable device identity is missing
- the helper cannot prove that the pending request corresponds to the local CLI device

## Command Summary

```bash
./tests/test-openclaw-pairing-state.sh <sandbox-name> --label pre-recovery
./lib/map-openclaw-cli-approval-target.sh <sandbox-name> --format text
./lib/apply-openclaw-cli-approval.sh <sandbox-name> --format text
./tests/test-openclaw-pairing-state.sh <sandbox-name> --label post-recovery
openclaw agent --agent main --json -m "Reply with exactly: pong"
./tests/test-openshell-gateway-inference.sh
```

## Related Files

- `docs/troubleshooting.md`
- `docs/scripts.md`
- `docs/adr/0001-inference-timeout.md`
- `docs/rca/2026-04-04-nemoclaw-374a847-regression.md`
