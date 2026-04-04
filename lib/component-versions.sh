#!/usr/bin/env bash

# Central component pins for this repository.
# Update this file when changing the known-good OpenShell or NemoClaw source.
#
# Important:
# - OpenShell has release tags, but NemoClaw currently moves faster and may
#   need to be pinned by commit SHA.
# - Treat the OpenShell + NemoClaw combination as one compatibility set.

# Human-readable compatibility set identifier for the current default pins.
COMPATIBILITY_SET_ID="${COMPATIBILITY_SET_ID:-jetson-orin-2026-04-03-v0.0.22-bootstrap}"

# OpenShell cluster and CLI release pins.
OPEN_SHELL_VERSION_PIN="${OPEN_SHELL_VERSION_PIN:-0.0.22}"
OPEN_SHELL_CLI_VERSION_PIN="${OPEN_SHELL_CLI_VERSION_PIN:-v${OPEN_SHELL_VERSION_PIN}}"

# NemoClaw source selection.
# Set NEMOCLAW_GIT_REF to:
# - a commit SHA such as 5c269c1 to pin a known-good revision
# - latest to follow the default branch HEAD
NEMOCLAW_REPO_URL="${NEMOCLAW_REPO_URL:-https://github.com/NVIDIA/NemoClaw.git}"
NEMOCLAW_GIT_REF="${NEMOCLAW_GIT_REF:-latest}"
