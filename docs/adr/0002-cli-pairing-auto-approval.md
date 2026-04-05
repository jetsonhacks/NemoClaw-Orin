# ADR 0002: Auto-approve the local CLI pairing request after onboard
**Status:** Accepted
**Date:** 2026-04-05
**Deciders:** Jim
**RCA reference:** [docs/rca/2026-04-04-nemoclaw-374a847-regression.md](../rca/2026-04-04-nemoclaw-374a847-regression.md)

---

## Context

During investigation of the April 4, 2026 NemoClaw regression, a fresh onboard
completed successfully but `openclaw tui` immediately failed with `Pairing
required`.

The RCA confirmed that upstream NemoClaw commit `2804b74` changed the
entrypoint-side auto-pair watcher to allow only:

```python
ALLOWED_CLIENTS = {'openclaw-control-ui'}
ALLOWED_MODES   = {'webchat'}
```

The local CLI/TUI presents as `clientId: "cli"` and `clientMode: "cli"`, so
the startup watcher rejects it and leaves the request pending.

This repository already includes host-side helpers that can safely identify and
approve the pending CLI request when it matches the durable local device
identity:

- `lib/map-openclaw-cli-approval-target.sh`
- `lib/apply-openclaw-cli-approval.sh`

Before this change, the workflow was manual and easy to forget. That produced a
poor first-run experience immediately after onboard and after some recovery
flows, and it also interacted badly with inference behavior because pairing
failure could force the agent into the embedded fallback path.

The upstream fix should still be to expand NemoClaw's allowlist for CLI/TUI
clients. This ADR only covers the local repository behavior while waiting for
upstream to land.

---

## Decision

Adopt a local, host-side auto-approval step for the CLI/TUI device as part of
the repository workflow.

Apply the helper automatically in:

- `onboard-nemoclaw.sh` via `ensure_cli_pairing` after `nemoclaw onboard`
- `recover-sandbox.sh` as part of the successful recovery path

The implementation must use the repository safety gate rather than approving
arbitrary pending requests:

```bash
./lib/apply-openclaw-cli-approval.sh <sandbox-name> --format json --quiet
```

Behavioral rules:

- if the helper reports `applied_cli_approve_request_id`, log success
- if the helper reports `noop_already_paired`, treat it as healthy and continue
- if the helper refuses or cannot determine a safe target, warn and continue
- failure is non-fatal; onboard and recovery should still complete with
  diagnostic guidance

This decision intentionally automates only the local CLI/TUI case already
covered by the repo helper. It does not attempt to approve unknown clients or
weaken OpenClaw pairing policy more broadly.

---

## Alternatives considered

### 1. Keep the workflow manual

This was the previous behavior:

```bash
./lib/apply-openclaw-cli-approval.sh <sandbox-name> --format text
```

It works, but it is too easy to miss during onboarding and recovery, and it
leaves the repository's "happy path" in a broken state for local CLI/TUI use.

**Rejected.** The manual workaround is operationally correct but not reliable
enough as the default workflow.

### 2. Auto-approve any pending request

This would be simpler to script, but it would bypass the repository's existing
device-identity matching logic and could approve the wrong client when multiple
requests are pending.

**Rejected.** Too risky.

### 3. Wait for the upstream NemoClaw fix and do nothing locally

This keeps the local workflow minimal, but it leaves current Jetson users with
a known broken onboarding result until upstream behavior changes and this repo
rebases onto it.

**Rejected.** The repository's purpose is to provide a reliable local workflow
now, not only after upstream changes land.

### 4. Disable pairing entirely for CLI/TUI paths

This would require broader auth changes in OpenClaw/NemoClaw and would alter
security semantics rather than narrowly repairing the broken integration path.

**Rejected.** Out of scope and not justified for a local workaround.

---

## Consequences

**Positive:**
- `openclaw tui` works immediately after a successful onboard in the normal
  local Jetson workflow
- recovery flows are less likely to leave the user stuck in `Pairing required`
- the local automation uses the existing safe-mapping helper rather than
  inventing a second approval path
- reducing pairing failures also reduces the chance of embedded fallback during
  agent turns

**Negative / risks:**
- approval remains local-workflow glue, not an upstream fix
- pairing state can still be lost across reconnects or restarts, so the helper
  may need to run again on future sessions
- if the helper cannot prove the pending request belongs to the local CLI
  device, the scripts only warn; they do not self-heal further

**Upstream action needed:**
- keep pursuing the NemoClaw-side fix so `"cli"` is handled in the startup
  auto-pair watcher
- once upstream behavior is reliable, re-evaluate whether this local
  auto-approval step should stay as a compatibility fallback or be removed
