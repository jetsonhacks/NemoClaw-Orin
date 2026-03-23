# Providers for NemoClaw on Jetson

These scripts live in the `providers/` directory and are intended to be run **after** `nemoclaw onboard` completes successfully.

They help you create named OpenShell provider records for local inference backends and, if requested, switch the active `inference.local` route to one of them.

> **Note:** OpenShell and NemoClaw are under active early development. The constraints, CLI commands, and behaviors described in this document reflect the current release and may change in future versions. If something described here does not match what you observe, check the [OpenShell release notes](https://docs.nvidia.com/openshell/latest/about/release-notes.html) and the [NemoClaw repository](https://github.com/NVIDIA/NemoClaw) for recent changes.

## Mental model

There are three related but different concepts:

- **Provider**: a saved connection profile for an upstream inference service
- **Model**: the model name or model ID to request from that provider
- **`inference.local`**: the stable HTTPS endpoint that all sandboxed code calls for inference — `https://inference.local/v1`

The provider record tells OpenShell **how to reach** an upstream inference service.
The model setting tells OpenShell **which model to request** from that service.
Code inside the sandbox always calls `https://inference.local/v1`, and OpenShell routes that traffic to the currently active provider and model.

That means your agent code does not need to know whether the backend is:

- a local Ollama instance
- a local vLLM server
- an external NIM or other hosted provider created during onboarding

## One active backend at a time

For a given OpenShell gateway, `inference.local` points to **one active provider/model pair at a time**.

You can switch between providers — a hosted provider from onboarding, `ollama-local`, `vllm-local` — but each switch replaces the previous route. All sandboxes on the gateway immediately start using the new backend. There is no way to have multiple backends active simultaneously through `inference.local`.

Keep this in mind before switching: if other sandboxes are running against the current backend, they will be affected.

## What the scripts do

### `configure-provider-ollama-local.sh`

Creates or refreshes a provider record named `ollama-local` by default, pointing to:

```text
http://host.openshell.internal:11434/v1
```

This assumes Ollama is running on the Jetson host, bound to `0.0.0.0`, and reachable on port `11434`. The script verifies the host endpoint is reachable before creating the provider.

### `configure-provider-vllm-local.sh`

Creates or refreshes a provider record named `vllm-local` by default, pointing to:

```text
http://host.openshell.internal:8000/v1
```

This assumes vLLM is running on the Jetson host, bound to `0.0.0.0`, and reachable on port `8000`. The script verifies the host endpoint is reachable before creating the provider.

## Default behavior

Both scripts:

- check that `openshell` is installed and reachable
- check that the relevant host inference server is reachable (**the server must be running when you run the script**, or it will fail — see Troubleshooting if you need to configure the provider before starting the server)
- recreate the provider record by default
- **do not switch** `inference.local` unless you explicitly provide a model

That last point matters: after running either script without a model name, your sandbox is still pointed at whatever backend NemoClaw onboarding originally configured. The provider record exists, but nothing has changed until you explicitly switch the inference route.

## Binding your local server to 0.0.0.0

The OpenShell gateway runs inside a Docker container. From inside the container, `localhost` and `127.0.0.1` refer to the container itself, not to the Jetson host. Inference requests routed through `host.openshell.internal` will fail to connect if your local server is only bound to `127.0.0.1`.

**Ollama** must be started with:

```bash
OLLAMA_HOST=0.0.0.0 ollama serve
```

Or set it permanently in `/etc/systemd/system/ollama.service`:

```
Environment="OLLAMA_HOST=0.0.0.0"
```

**vLLM** must be started with `--host 0.0.0.0`. Both `nemotron3-thor.sh` and `nemotron3-thor-no-thinking.sh` already do this.

## Typical workflow

### 1. Onboard NemoClaw

Run your normal Jetson onboarding flow first.

### 2. Record the original inference configuration

Before creating any new providers, record what NemoClaw onboarding configured so you can switch back to it later:

```bash
openshell inference get
openshell provider list
```

Write down the provider name and model shown by `openshell inference get`. You will need these values if you want to switch back to the original backend after testing a local provider.

### 3. Start your local inference server

Make sure Ollama or vLLM is running and bound to `0.0.0.0` before continuing. See the binding section above.

### 4. Create one or more provider records

Create the local Ollama provider:

```bash
./configure-provider-ollama-local.sh
```

Create the local vLLM provider:

```bash
./configure-provider-vllm-local.sh
```

### 5. See what providers exist

```bash
openshell provider list
```

### 6. Switch the active inference backend when needed

Switch to Ollama:

```bash
openshell inference set --provider ollama-local --model 'llama3.2:3b'
```

Switch to local vLLM:

```bash
openshell inference set --provider vllm-local --model 'meta-llama/Llama-3.2-3B-Instruct'
```

Switch back to the provider from onboarding (use the values you recorded in Step 2):

```bash
openshell inference set --provider '<original-provider-name>' --model '<original-model-name>'
```

## Activating during provider creation

If you already know the model you want to use, either script can create the provider and switch `inference.local` in one step.

Example for Ollama:

```bash
MODEL_NAME='llama3.2:3b' ./configure-provider-ollama-local.sh
```

Example for vLLM:

```bash
MODEL_NAME='meta-llama/Llama-3.2-3B-Instruct' ./configure-provider-vllm-local.sh
```

## Host assumptions

### Ollama

These defaults assume Ollama is available on the host, bound to `0.0.0.0`, and listening on port `11434`.

Default provider base URL (used inside the gateway container):

```text
http://host.openshell.internal:11434/v1
```

Host-side health check used by the script (checked from the host, before creating the provider):

```text
http://127.0.0.1:11434/api/tags
```

### vLLM

These defaults assume vLLM is available on the host, bound to `0.0.0.0`, and listening on port `8000`.

Default provider base URL (used inside the gateway container):

```text
http://host.openshell.internal:8000/v1
```

Host-side health check used by the script (checked from the host, before creating the provider):

```text
http://127.0.0.1:8000/v1/models
```

## Useful overrides

### Common overrides

```bash
PROVIDER_NAME='my-provider-name' ./configure-provider-ollama-local.sh
FORCE_RECREATE_PROVIDER=false ./configure-provider-vllm-local.sh
INFERENCE_NO_VERIFY=true MODEL_NAME='some-model' ./configure-provider-ollama-local.sh
```

### Ollama-specific

```bash
OPENAI_BASE_URL='http://host.openshell.internal:11434/v1' ./configure-provider-ollama-local.sh
OLLAMA_HOST_CHECK_URL='http://127.0.0.1:11434/api/tags' ./configure-provider-ollama-local.sh
SKIP_OLLAMA_HOST_CHECK=true ./configure-provider-ollama-local.sh
SKIP_MODEL_PRESENCE_CHECK=true MODEL_NAME='llama3.2:3b' ./configure-provider-ollama-local.sh
```

### vLLM-specific

```bash
OPENAI_BASE_URL='http://host.openshell.internal:8000/v1' ./configure-provider-vllm-local.sh
VLLM_HOST_CHECK_URL='http://127.0.0.1:8000/v1/models' ./configure-provider-vllm-local.sh
SKIP_VLLM_HOST_CHECK=true ./configure-provider-vllm-local.sh
SKIP_MODEL_PRESENCE_CHECK=true MODEL_NAME='meta-llama/Llama-3.2-3B-Instruct' ./configure-provider-vllm-local.sh
```

## Troubleshooting

### `openshell status` fails

The OpenShell gateway is not up yet, or onboarding did not complete successfully.

### The script fails because the local backend is not running yet

Both scripts check that the local inference server is reachable before creating the provider. If you want to create the provider record before starting the server, skip the host check:

For Ollama:

```bash
SKIP_OLLAMA_HOST_CHECK=true ./configure-provider-ollama-local.sh
```

For vLLM:

```bash
SKIP_VLLM_HOST_CHECK=true ./configure-provider-vllm-local.sh
```

If you also want to switch `inference.local` before the server is up, add `INFERENCE_NO_VERIFY=true` to skip the endpoint verification that `openshell inference set` performs:

```bash
SKIP_OLLAMA_HOST_CHECK=true INFERENCE_NO_VERIFY=true \
  MODEL_NAME='llama3.2:3b' ./configure-provider-ollama-local.sh
```

### Provider is created, but NemoClaw is still using the old backend

Creating a provider record does not automatically switch `inference.local`.
Check the active route:

```bash
openshell inference get
```

Then explicitly switch it:

```bash
openshell inference set --provider '<provider-name>' --model '<model-name>'
```

### The script says the local backend is unreachable

First verify the host service is up and responding:

For Ollama:

```bash
curl http://127.0.0.1:11434/api/tags
```

For vLLM:

```bash
curl http://127.0.0.1:8000/v1/models
```

If those succeed but inference still fails from inside the sandbox, the server is likely bound to `127.0.0.1` instead of `0.0.0.0`. The gateway container cannot reach a server bound only to localhost. See the binding section above.

### I do not know the original provider name created during onboarding

```bash
openshell provider list
openshell inference get
```

`openshell inference get` shows the provider and model currently active. `openshell provider list` shows all configured providers. This is why Step 2 of the workflow recommends recording these values before making any changes.