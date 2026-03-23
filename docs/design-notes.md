# Design notes

This repository keeps the Jetson-specific workaround local and explicit.

The guiding assumptions are:

- the gateway container image needs to be patched locally for this Jetson path
- setup and onboarding should stay separate because onboarding is the more memory-sensitive phase
- the first-run path should be simple for users, while deeper operational detail lives in supporting docs
- recovery after reboot should normally mean starting the gateway again and reconnecting, not rebuilding or recreating state
