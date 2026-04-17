# Changelog

## v0.0.5 April, 2026

- reposition the repository as a JetsonHacks transition/helper repo instead of the primary NemoClaw install path
- route new installs to upstream NVIDIA/NemoClaw
- add migration guidance for older JetsonHacks installs that used a patched local `~/NemoClaw` clone
- keep `forward-openclaw.sh` visible as the main retained helper
- mark older setup, onboard, restart, and recovery scripts as legacy/reference material

## v0.0.4 April, 2026

- add automatic local CLI pairing approval after onboard and recovery
- re-apply a 120-second OpenShell managed inference timeout during onboard and recovery
- restore the onboarding-selected provider/model when gateway inference is unset after onboard
- add direct Ollama benchmark tooling under `benchmarks/`
- document the regression investigation and local decisions with RCA and ADR records

Tested with:

- OpenShell `v0.0.22`
- NemoClaw commit `374a847`

## v0.0.3 April, 2026

- tested on Jetson AGX Orin and Orin Nano
- bootstrap target moved to OpenShell `v0.0.22`
- default setup now uses the upstream cluster image instead of a locally patched image
- OpenShell now handles SSH handshake persistence upstream
- OpenShell now persists sandbox state across gateway stop and start cycles

## v0.0.2 April, 2026

- tested on Jetson AGX Orin and Orin Nano
- moved to OpenShell `v0.0.20`

## Initial Release March, 2026

- tested on Jetson Orin Nano
- initial Jetson-oriented NemoClaw bringup and recovery workflow
