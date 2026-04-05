# Benchmarks

Standalone benchmark helpers that do not depend on the NemoClaw/OpenShell path.

## `ollama-benchmark.sh`

Benchmarks direct Ollama inference over the native Ollama HTTP API.

It is useful for separating:

- estimated time to first token
- model load time
- prompt evaluation time
- generation time
- prompt-processing throughput in tokens per second
- generation throughput in tokens per second
- cold-versus-warm behavior

Example usage:

```bash
./benchmarks/ollama-benchmark.sh --model gemma4:e4b
./benchmarks/ollama-benchmark.sh --model gemma4:e4b --scenario synthetic --synthetic-bytes 51802
./benchmarks/ollama-benchmark.sh --model gemma4:e4b --prompt-file ./prompt.txt --system-file ./system.txt --runs 3
```

Requirements:

- `curl`
- `python3`
- a reachable Ollama server, by default at `http://127.0.0.1:11434`

The script reports whether the model appeared loaded before the first run, so
you can tell whether run 1 was truly cold or already warm. It also labels very
high repeated-run prompt throughput as `cached/reused` so cache hits do not get
misread as normal fresh prompt-processing speed. The summary includes a short
plain-language takeaway so the output is easier to interpret at a glance.
The time-to-first-token value is an estimate derived from Ollama's reported
load, prompt-eval, and average per-token generation durations.

## Comparing Against NemoClaw

Use the standalone Ollama benchmark as a baseline first, then compare it
against a freshly onboarded NemoClaw environment using the same model. This
helps separate raw model/runtime performance from additional latency introduced
by onboarding, gateway configuration, agent context, and end-to-end NemoClaw
request handling.
