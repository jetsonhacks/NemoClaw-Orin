# JetsonHacks NemoClaw Transition Helpers

Jetson-specific helpers and transition notes for running NVIDIA NemoClaw on Jetson systems.

This repository is no longer the primary install path for NemoClaw on Jetson. New installs should use upstream NVIDIA/NemoClaw:

- NVIDIA/NemoClaw: <https://github.com/NVIDIA/NemoClaw>
- NemoClaw docs: <https://docs.nvidia.com/nemoclaw/>

This repo now exists to keep older JetsonHacks viewers oriented, preserve Jetson-specific notes, and retain the small helper that is still useful after an upstream install: `forward-openclaw.sh`.

In short:

- new installs go upstream
- this repo is for Jetson-specific helpers and migration notes
- `forward-openclaw.sh` is the main retained helper
- older setup, onboard, restart, and recovery scripts are legacy

## If You Came Here From the Older Video/Blog, Read This First

Older JetsonHacks content pointed here because this repo carried the Jetson install flow while upstream support was still moving quickly. That is no longer the recommended path.

Use upstream NVIDIA/NemoClaw for a fresh install. Treat this repository as a transition/helper repo, not the installer.

The old top-level setup, onboard, restart, and recovery scripts are retained for reference only. They mostly duplicate behavior that now belongs upstream.

## Migration Notes for Older JetsonHacks Installs

Older versions of this repository installed and patched a local `~/NemoClaw` clone.

For a clean move to upstream:

1. Use the matching legacy maintenance script under `lib/maintenance/` for the old JetsonHacks-managed flow you used.
2. Confirm the old JetsonHacks-managed pieces are gone, including the patched `~/NemoClaw` checkout where applicable.
3. Install again from upstream NVIDIA/NemoClaw.

For example, `lib/maintenance/uninstall-setup-jetson-orin.sh` undoes the legacy `setup-jetson-orin.sh` setup flow.

The maintenance scripts are preferred because they remove what the old JetsonHacks setup flow created. If you already cleaned up manually and an old patched `~/NemoClaw` checkout is still present, remove it only after confirming it is not a separate checkout you still need.

## Still Useful Here

### `forward-openclaw.sh`

Use this helper when an existing upstream-created NemoClaw sandbox is running but you want a predictable local browser forward for OpenClaw.

```bash
./forward-openclaw.sh <sandbox-name>
./forward-openclaw.sh <sandbox-name> --status
./forward-openclaw.sh <sandbox-name> --stop
```

By default it manages a host-side forward on `127.0.0.1:18789`.

## Legacy Scripts

These root-level scripts are legacy JetsonHacks install/recovery helpers. They are kept so older posts, videos, and troubleshooting references still make sense, but they are not the recommended workflow for new installs.

- `setup-jetson-orin.sh` - legacy JetsonHacks host setup flow
- `onboard-nemoclaw.sh` - legacy JetsonHacks onboarding wrapper
- `restart-nemoclaw.sh` - legacy OpenShell gateway restart helper
- `recover-sandbox.sh` - legacy sandbox recovery helper

Supporting directories such as `lib/`, `providers/`, `benchmarks/`, and `docs/` are mostly historical support material for those scripts. Some notes may still be useful for debugging or provider experiments, but they should not replace the upstream install guide.

## Upstream Install Pointer

For new installs and normal day-to-day setup, use the upstream `nemoclaw` CLI and documentation.

Start here:

- <https://github.com/NVIDIA/NemoClaw>
- <https://docs.nvidia.com/nemoclaw/>

## Release Notes

Current release: `v0.0.5 April, 2026`

- reposition the repository as a JetsonHacks transition/helper repo instead of the primary NemoClaw install path
- route new installs to upstream NVIDIA/NemoClaw
- add migration guidance for older JetsonHacks installs that used a patched local `~/NemoClaw` clone
- keep `forward-openclaw.sh` visible as the main retained helper
- mark older setup, onboard, restart, and recovery scripts as legacy/reference material

Older release history is in [CHANGELOG.md](CHANGELOG.md).

## Repository Status

This repository is in transition. The front page is intentionally compact so viewers arriving from older JetsonHacks material can quickly see what changed, how to migrate, and which helper remains relevant.
