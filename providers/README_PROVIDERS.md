# Providers for NemoClaw on Jetson

These scripts live in the `providers/` directory and are intended to be run after `nemoclaw onboard` completes successfully.

They help you manage the OpenShell gateway inference provider used by NemoClaw. In practical terms, they let you point `inference.local` at a local Ollama server, a local vLLM server, NVIDIA Endpoints, or back to the original provider selected during onboarding.

> Note: OpenShell and NemoClaw are under active early development. The commands and behavior described here reflect the current repository state and may change over time.

## Mental model

There are three related but different concepts:

- Provider: a saved connection profile for an upstream inference service
- Model: the model name or model ID to request from that provider
- `inference.local`: the stable HTTPS endpoint used by sandboxed code for inference, `https://inference.local/v1`

The provider tells OpenShell how to reach the upstream service.
The model tells OpenShell what model to request from that service.
Code inside the sandbox always calls `https://inference.local/v1`, and OpenShell routes that traffic to the currently active provider and model.

That means your agent code does not need to know whether the backend is:

- a local Ollama instance
- a local vLLM server
- NVIDIA Endpoints
- a hosted provider selected during onboarding

For NVIDIA Endpoints, the default provider name in this repository is `nvidia-prod` to match NemoClaw's published provider examples.

For OpenAI-compatible endpoints, the provider script validates with a real inference request when you pass a model, instead of assuming `/models` is authoritative. That matches NemoClaw's documented guidance for compatible endpoints.

## Local Ollama choices

This repository supports two local Ollama installation styles on Jetson.

- `./providers/install-ollama-jetson.sh`
  Docker-managed Ollama. This remains the default path.
- `./providers/install-ollama-host-jetson.sh`
  Host-managed Ollama. This is the native Ollama path for users who want faster access to upstream releases and newly supported models.

Choose the Docker-managed path when you want stronger isolation, easier cleanup, and behavior that matches the rest of this repository's controlled bringup and recovery model.

Choose the host-managed path when you care more about day-one availability of new Ollama versions and models, or when you are already comfortable managing Ollama directly on the host.

The two install styles do not share a model library automatically.

- Docker-managed Ollama stores models in its Docker volume.
- Host-managed Ollama stores models in the host Ollama data directory for the account or service that runs it.

If you pull a model in one mode, it will not automatically appear in the other mode.

Run only one local Ollama service at a time.

- If you switch from Docker-managed Ollama to host-managed Ollama, stop the Docker container first with `docker stop ollama`.
- If you switch from host-managed Ollama to Docker-managed Ollama, stop the host service first with `sudo systemctl stop ollama`.

This avoids port conflicts on `11434` and makes it clear which Ollama model library you are managing.

## One active backend at a time

For a given OpenShell gateway, `inference.local` points to one active provider/model pair at a time.

You can switch between providers such as:

- the original hosted provider selected during onboarding
- `ollama-local`
- `vllm-local`
- a custom provider name you define

Each switch replaces the previous route. All sandboxes on that gateway immediately start using the new backend.

## Typical Ollama flow

Docker-managed Ollama:

```bash
./providers/install-ollama-jetson.sh --model qwen3.5:9b
./providers/configure-ollama-local.sh --model qwen3.5:9b
```

Host-managed Ollama:

```bash
./providers/install-ollama-host-jetson.sh --model qwen3.5:9b
./providers/configure-ollama-local.sh --model qwen3.5:9b
```

Once configured, sandboxed code still talks to the same stable endpoint:

```text
https://inference.local/v1
```

## Script summary

- `./providers/configure-gateway-provider.sh`
  Show provider status, create or refresh a provider definition, and optionally activate a provider/model pair.
- `./providers/configure-ollama-local.sh`
  Convenience wrapper for configuring and activating the local Ollama provider with an explicit model.
- `./providers/manage-ollama-models.sh`
  List, pull, and remove models from a reachable Ollama server. This works with either local Ollama install style as long as the API endpoint is reachable.
- `./providers/install-ollama-jetson.sh`
  Install and run Ollama in Docker on Jetson.
- `./providers/install-ollama-host-jetson.sh`
  Install and run Ollama directly on the Jetson host.
- `./providers/uninstall-ollama-jetson.sh`
  Remove the Docker-managed Ollama installation created by `install-ollama-jetson.sh`.
