# Providers for NemoClaw on Jetson

These scripts live in the `providers/` directory and are intended to be run **after** `nemoclaw onboard` completes successfully.

They help you manage the OpenShell gateway inference provider used by NemoClaw. In practical terms, they let you point `inference.local` at a local Ollama server, a local vLLM server, or back to the original provider selected during onboarding.

> **Note:** OpenShell and NemoClaw are under active early development. The commands and behavior described here reflect the current repository state and may change over time.

## Mental model

There are three related but different concepts:

- **Provider**: a saved connection profile for an upstream inference service
- **Model**: the model name or model ID to request from that provider
- **`inference.local`**: the stable HTTPS endpoint used by sandboxed code for inference — `https://inference.local/v1`

The provider tells OpenShell **how to reach** the upstream service.
The model tells OpenShell **what model to request** from that service.
Code inside the sandbox always calls `https://inference.local/v1`, and OpenShell routes that traffic to the currently active provider and model.

That means your agent code does not need to know whether the backend is:

- a local Ollama instance
- a local vLLM server
- a hosted provider selected during onboarding

## One active backend at a time

For a given OpenShell gateway, `inference.local` points to **one active provider/model pair at a time**.

You can switch between providers such as:

- the original hosted provider selected during onboarding
- `ollama-local`
- `vllm-local`
- a custom provider name you define

But each switch replaces the previous route. All sandboxes on that gateway immediately start using the new backend.

There is no multi-provider fanout through `inference.local`. Keep that in mind before switching if other sandboxes are active.

## The scripts

### `configure-gateway-provider.sh`

This is the main provider configuration tool.

It can:

- show current gateway provider status
- list configured providers
- create or refresh one named provider definition
- optionally activate that provider and model for gateway inference
- switch back to the original onboarding provider and model

Default behavior with no arguments:

```bash
./providers/configure-gateway-provider.sh