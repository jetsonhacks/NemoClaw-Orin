#!/usr/bin/env bash
set -Eeuo pipefail

# Benchmark direct Ollama request performance without going through NemoClaw.
#
# The script sends repeated native Ollama /api/generate requests and reports:
# - whether the model appeared loaded before the run
# - estimated time to first token
# - end-to-end wall-clock time
# - Ollama-reported load, prompt-eval, and generation durations
# - prompt and response token counts
# - whether repeated runs show evidence of prompt-prefix reuse

OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://127.0.0.1:11434}"
MODEL_NAME="${MODEL_NAME:-}"
PROMPT_FILE=""
SYSTEM_FILE=""
PROMPT_TEXT=""
SYSTEM_TEXT=""
SCENARIO="minimal"
SYNTHETIC_BYTES=51802
RUNS=2
KEEP_ALIVE="${KEEP_ALIVE:-5m}"
TEMPERATURE="${TEMPERATURE:-0}"
MAX_TOKENS="${MAX_TOKENS:-64}"
CURL_TIMEOUT_SECONDS="${CURL_TIMEOUT_SECONDS:-0}"

TMP_PS=""

cleanup() {
  rm -f "$TMP_PS"
}
trap cleanup EXIT

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf '[ERROR] Missing required command: %s\n' "$1" >&2
    exit 1
  }
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF_USAGE'
Usage:
  ./benchmarks/ollama-benchmark.sh --model <model-name> [options]

Examples:
  ./benchmarks/ollama-benchmark.sh --model gemma4:e4b
  ./benchmarks/ollama-benchmark.sh --model gemma4:e4b --scenario synthetic --synthetic-bytes 51802
  ./benchmarks/ollama-benchmark.sh --model gemma4:e4b --prompt-file ./prompt.txt --system-file ./system.txt --runs 3
  OLLAMA_BASE_URL=http://jetson:11434 ./benchmarks/ollama-benchmark.sh --model qwen3.5:7b

Options:
  --model <name>              Ollama model to benchmark. Required.
  --host <url>                Ollama base URL. Default: http://127.0.0.1:11434
  --scenario <name>           minimal or synthetic. Default: minimal
  --synthetic-bytes <n>       Target prompt size for synthetic scenario. Default: 51802
  --prompt <text>             Prompt text to send directly
  --prompt-file <path>        Read prompt text from file
  --system-file <path>        Read system prompt from file
  --runs <n>                  Number of back-to-back requests. Default: 2
  --keep-alive <value>        Ollama keep_alive value. Default: 5m
  --temperature <value>       Generation temperature. Default: 0
  --max-tokens <n>            num_predict value. Default: 64
  --timeout-seconds <n>       curl max-time. 0 means no limit. Default: 0
  --help                      Show this help

Notes:
  - This script talks directly to Ollama's native HTTP API.
  - It does not require OpenShell, NemoClaw, or an OpenAI-compatible adapter.
  - A true cold run requires the model to be unloaded before run 1. The script
    reports whether the model already appeared loaded when the benchmark began.
EOF_USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --model)
        [[ $# -ge 2 ]] || die "--model requires a value"
        MODEL_NAME="$2"
        shift 2
        ;;
      --host)
        [[ $# -ge 2 ]] || die "--host requires a value"
        OLLAMA_BASE_URL="$2"
        shift 2
        ;;
      --scenario)
        [[ $# -ge 2 ]] || die "--scenario requires a value"
        SCENARIO="$2"
        shift 2
        ;;
      --synthetic-bytes)
        [[ $# -ge 2 ]] || die "--synthetic-bytes requires a value"
        SYNTHETIC_BYTES="$2"
        shift 2
        ;;
      --prompt)
        [[ $# -ge 2 ]] || die "--prompt requires a value"
        PROMPT_TEXT="$2"
        shift 2
        ;;
      --prompt-file)
        [[ $# -ge 2 ]] || die "--prompt-file requires a path"
        PROMPT_FILE="$2"
        shift 2
        ;;
      --system-file)
        [[ $# -ge 2 ]] || die "--system-file requires a path"
        SYSTEM_FILE="$2"
        shift 2
        ;;
      --runs)
        [[ $# -ge 2 ]] || die "--runs requires a value"
        RUNS="$2"
        shift 2
        ;;
      --keep-alive)
        [[ $# -ge 2 ]] || die "--keep-alive requires a value"
        KEEP_ALIVE="$2"
        shift 2
        ;;
      --temperature)
        [[ $# -ge 2 ]] || die "--temperature requires a value"
        TEMPERATURE="$2"
        shift 2
        ;;
      --max-tokens)
        [[ $# -ge 2 ]] || die "--max-tokens requires a value"
        MAX_TOKENS="$2"
        shift 2
        ;;
      --timeout-seconds)
        [[ $# -ge 2 ]] || die "--timeout-seconds requires a value"
        CURL_TIMEOUT_SECONDS="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

validate_args() {
  [[ -n "$MODEL_NAME" ]] || die "--model is required"
  [[ "$RUNS" =~ ^[0-9]+$ ]] || die "--runs must be an integer"
  [[ "$RUNS" -ge 1 ]] || die "--runs must be at least 1"
  [[ "$SYNTHETIC_BYTES" =~ ^[0-9]+$ ]] || die "--synthetic-bytes must be an integer"
  [[ "$MAX_TOKENS" =~ ^[0-9]+$ ]] || die "--max-tokens must be an integer"
  [[ "$CURL_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || die "--timeout-seconds must be an integer"

  case "$SCENARIO" in
    minimal|synthetic) ;;
    *)
      die "--scenario must be one of: minimal, synthetic"
      ;;
  esac

  [[ -z "$PROMPT_FILE" || -f "$PROMPT_FILE" ]] || die "Prompt file not found: $PROMPT_FILE"
  [[ -z "$SYSTEM_FILE" || -f "$SYSTEM_FILE" ]] || die "System file not found: $SYSTEM_FILE"
}

load_text_inputs() {
  if [[ -n "$PROMPT_FILE" ]]; then
    PROMPT_TEXT="$(<"$PROMPT_FILE")"
  elif [[ -z "$PROMPT_TEXT" ]]; then
    case "$SCENARIO" in
      minimal)
        PROMPT_TEXT='Reply with exactly this text and nothing else: benchmark-ok'
        ;;
      synthetic)
        PROMPT_TEXT="$(python3 - "$SYNTHETIC_BYTES" <<'PY'
import sys

target = int(sys.argv[1])
seed = (
    "OpenClaw agent benchmark context. "
    "This prompt exists to measure prompt evaluation throughput on a direct Ollama request. "
    "Repeat the structure without changing the meaning. "
)

chunks = []
size = 0
counter = 1
while size < target:
    line = (
        f"[section {counter:04d}] {seed}"
        "Tool schemas, workspace policy, and repository instructions are intentionally omitted; "
        "this is synthetic benchmark filler to produce a stable large prompt.\n"
    )
    chunks.append(line)
    size += len(line.encode("utf-8"))
    counter += 1

text = "".join(chunks)
sys.stdout.write(text)
PY
)"
        ;;
    esac
  fi

  if [[ -n "$SYSTEM_FILE" ]]; then
    SYSTEM_TEXT="$(<"$SYSTEM_FILE")"
  fi
}

fetch_loaded_state() {
  local ps_url="${OLLAMA_BASE_URL%/}/api/ps"
  if ! curl --silent --show-error --fail "$ps_url" >"$TMP_PS" 2>/dev/null; then
    printf 'unknown'
    return 0
  fi

  python3 - "$TMP_PS" "$MODEL_NAME" <<'PY'
import json
import sys

path = sys.argv[1]
model = sys.argv[2]

with open(path) as f:
    data = json.load(f)

for item in data.get("models", []):
    if not isinstance(item, dict):
        continue
    if item.get("name") == model:
        print("yes")
        raise SystemExit(0)

print("no")
PY
}

build_request_json() {
  MODEL_NAME="$MODEL_NAME" \
  PROMPT_TEXT="$PROMPT_TEXT" \
  SYSTEM_TEXT="$SYSTEM_TEXT" \
  KEEP_ALIVE="$KEEP_ALIVE" \
  TEMPERATURE="$TEMPERATURE" \
  MAX_TOKENS="$MAX_TOKENS" \
  python3 - <<'PY'
import json
import os

payload = {
    "model": os.environ["MODEL_NAME"],
    "prompt": os.environ["PROMPT_TEXT"],
    "stream": True,
    "keep_alive": os.environ["KEEP_ALIVE"],
    "options": {
        "temperature": float(os.environ["TEMPERATURE"]),
        "num_predict": int(os.environ["MAX_TOKENS"]),
    },
}

system = os.environ.get("SYSTEM_TEXT", "")
if system:
    payload["system"] = system

print(json.dumps(payload))
PY
}

run_single_request() {
  local run_number="$1"
  local request_json="$2"
  local generate_url="${OLLAMA_BASE_URL%/}/api/generate"
  RUN_NUMBER="$run_number" \
  REQUEST_JSON="$request_json" \
  GENERATE_URL="$generate_url" \
  CURL_TIMEOUT_SECONDS="$CURL_TIMEOUT_SECONDS" \
  python3 - <<'PY'
import json
import os
import subprocess
import time

run_number = int(os.environ["RUN_NUMBER"])
request_json = os.environ["REQUEST_JSON"]
generate_url = os.environ["GENERATE_URL"]
timeout_seconds = int(os.environ["CURL_TIMEOUT_SECONDS"])

def ns_to_s(ns):
    if ns in (None, "", 0):
        return "0.000"
    return f"{(int(ns) / 1_000_000_000):.3f}"

result = {
    "run": run_number,
    "http_code": "000",
    "wall_s": "0.000",
    "ttft_s": "0.000",
    "ttft_label": "estimated",
    "ok": False,
    "done_reason": "",
    "response_chars": 0,
    "response_preview": "",
    "load_s": "0.000",
    "prompt_eval_s": "0.000",
    "eval_s": "0.000",
    "total_s": "0.000",
    "prompt_tokens": "0",
    "response_tokens": "0",
    "prompt_tps": "0.0",
    "generation_tps": "0.0",
    "prompt_rate_label": "fresh",
    "error": "",
}

start_ns = time.monotonic_ns()
first_token_ns = None
response_parts = []
final_payload = None
http_code = "000"

cmd = [
    "curl",
    "--no-buffer",
    "--silent",
    "--show-error",
    "--header",
    "Content-Type: application/json",
    "--request",
    "POST",
    "--data",
    request_json,
    "--write-out",
    "\n__HTTP_CODE__:%{http_code}\n",
    generate_url,
]

if timeout_seconds > 0:
    cmd[1:1] = ["--max-time", str(timeout_seconds)]

try:
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
except OSError as exc:
    result["error"] = str(exc)
    result["wall_s"] = f"{(time.monotonic_ns() - start_ns) / 1_000_000_000:.3f}"
    print(json.dumps(result))
    raise SystemExit(0)

assert proc.stdout is not None
assert proc.stderr is not None

for raw_line in proc.stdout:
    line = raw_line.strip()
    if not line:
        continue
    if line.startswith("__HTTP_CODE__:"):
        http_code = line.split(":", 1)[1].strip()
        continue
    try:
        payload = json.loads(line)
    except json.JSONDecodeError:
        continue

    chunk_text = payload.get("response") or ""
    if chunk_text:
        response_parts.append(chunk_text)
        if first_token_ns is None:
            first_token_ns = time.monotonic_ns()

    if payload.get("done") is True:
        final_payload = payload

stderr_text = proc.stderr.read().strip()
proc.wait()

result["http_code"] = http_code

end_ns = time.monotonic_ns()
result["wall_s"] = f"{(end_ns - start_ns) / 1_000_000_000:.3f}"
if first_token_ns is not None:
    result["ttft_s"] = f"{(first_token_ns - start_ns) / 1_000_000_000:.3f}"

if proc.returncode != 0:
    result["error"] = stderr_text or f"curl exited with code {proc.returncode}"
    print(json.dumps(result))
    raise SystemExit(0)

if not str(result["http_code"]).startswith("2"):
    result["error"] = stderr_text or f"HTTP {result['http_code']}"
    print(json.dumps(result))
    raise SystemExit(0)

if not final_payload:
    result["error"] = stderr_text or "stream ended without a final completion object"
    print(json.dumps(result))
    raise SystemExit(0)

if "error" in final_payload:
    error_obj = final_payload.get("error")
    if isinstance(error_obj, dict):
        result["error"] = error_obj.get("message") or json.dumps(error_obj)
    else:
        result["error"] = str(error_obj)
    print(json.dumps(result))
    raise SystemExit(0)

response_text = "".join(response_parts)
result["ok"] = True
result["done_reason"] = final_payload.get("done_reason") or ""
result["response_chars"] = len(response_text)
result["response_preview"] = response_text[:120].replace("\n", " ")
result["load_s"] = ns_to_s(final_payload.get("load_duration"))
result["prompt_eval_s"] = ns_to_s(final_payload.get("prompt_eval_duration"))
result["eval_s"] = ns_to_s(final_payload.get("eval_duration"))
result["total_s"] = ns_to_s(final_payload.get("total_duration"))
result["prompt_tokens"] = str(final_payload.get("prompt_eval_count") or 0)
result["response_tokens"] = str(final_payload.get("eval_count") or 0)

prompt_eval_count = int(final_payload.get("prompt_eval_count") or 0)
eval_count = int(final_payload.get("eval_count") or 0)
prompt_eval_duration = int(final_payload.get("prompt_eval_duration") or 0)
eval_duration = int(final_payload.get("eval_duration") or 0)

if prompt_eval_count > 0 and prompt_eval_duration > 0:
    result["prompt_tps"] = f"{prompt_eval_count / (prompt_eval_duration / 1_000_000_000):.1f}"

if eval_count > 0 and eval_duration > 0:
    result["generation_tps"] = f"{eval_count / (eval_duration / 1_000_000_000):.1f}"

# Ollama does not expose token-by-token timestamps in the final payload. The
# most stable user-facing TTFT number we can derive is:
#   load_duration + prompt_eval_duration + average time for one generated token
if eval_count > 0 and eval_duration > 0:
    avg_token_ns = eval_duration / eval_count
    ttft_estimate_ns = prompt_eval_duration + int(final_payload.get("load_duration") or 0) + int(avg_token_ns)
    result["ttft_s"] = f"{ttft_estimate_ns / 1_000_000_000:.3f}"
elif prompt_eval_duration > 0 or int(final_payload.get("load_duration") or 0) > 0:
    ttft_estimate_ns = prompt_eval_duration + int(final_payload.get("load_duration") or 0)
    result["ttft_s"] = f"{ttft_estimate_ns / 1_000_000_000:.3f}"

if prompt_eval_count >= 1000 and prompt_eval_duration > 0:
    prompt_tps = prompt_eval_count / (prompt_eval_duration / 1_000_000_000)
    if prompt_tps >= 5000:
        result["prompt_rate_label"] = "cached"

print(json.dumps(result))
PY
}

print_header() {
  local initial_loaded="$1"
  local prompt_bytes=""
  local system_bytes=""

  prompt_bytes="$(PROMPT_TEXT="$PROMPT_TEXT" python3 - <<'PY'
import os
print(len(os.environ["PROMPT_TEXT"].encode("utf-8")))
PY
)"
  system_bytes="$(SYSTEM_TEXT="$SYSTEM_TEXT" python3 - <<'PY'
import os
print(len(os.environ.get("SYSTEM_TEXT", "").encode("utf-8")))
PY
)"

  printf 'Ollama Direct Benchmark\n\n'
  printf 'Model:                %s\n' "$MODEL_NAME"
  printf 'Ollama URL:           %s\n' "$OLLAMA_BASE_URL"
  printf 'Scenario:             %s\n' "$SCENARIO"
  printf 'Prompt bytes:         %s\n' "$prompt_bytes"
  printf 'System bytes:         %s\n' "$system_bytes"
  printf 'Runs:                 %s\n' "$RUNS"
  printf 'Keep-alive:           %s\n' "$KEEP_ALIVE"
  printf 'Model loaded at start:%s\n' " $initial_loaded"
  printf '\n'
}

print_run_report() {
  local result_json="$1"
  RESULT_JSON="$result_json" python3 - <<'PY'
import json
import os

r = json.loads(os.environ["RESULT_JSON"])
print(f"Run {r['run']}:")
print(f"  HTTP:           {r['http_code']}")
print(f"  Time to first token ({r['ttft_label']}): {r['ttft_s']} s")
print(f"  Full reply time:     {r['wall_s']} s")

if r["ok"]:
    print(f"  Ollama total:   {r['total_s']} s")
    print(f"  Load:           {r['load_s']} s")
    print(f"  Prompt eval:    {r['prompt_eval_s']} s")
    print(f"  Generation:     {r['eval_s']} s")
    print(f"  Prompt tokens:  {r['prompt_tokens']}")
    print(f"  Response tokens: {r['response_tokens']}")
    prompt_label = "cached/reused" if r["prompt_rate_label"] == "cached" else "fresh"
    print(f"  Prompt rate:    {r['prompt_tps']} tok/s ({prompt_label})")
    print(f"  Gen rate:       {r['generation_tps']} tok/s")
    if r["done_reason"]:
        print(f"  Done reason:    {r['done_reason']}")
    if r["response_preview"]:
        print(f"  Preview:        {r['response_preview']}")
else:
    print(f"  Error:          {r['error']}")
PY
}

print_summary() {
  RESULTS_JSON="$1" python3 - <<'PY'
import json
import os

results = json.loads(os.environ["RESULTS_JSON"])
ok_results = [r for r in results if r.get("ok")]

print("Summary:")
if not ok_results:
    print("  No successful runs were recorded.")
    raise SystemExit(0)

first = ok_results[0]
last = ok_results[-1]
print(f"  Successful runs: {len(ok_results)}")
print(f"  First token est.: {first['ttft_s']} s on run 1")
print(f"  Warm token est.:  {last['ttft_s']} s on run {last['run']}")
print(f"  First run wall:  {first['wall_s']} s")
print(f"  Last run wall:   {last['wall_s']} s")
print(f"  First prompt:    {first['prompt_eval_s']} s")
print(f"  Last prompt:     {last['prompt_eval_s']} s")
print(f"  First prompt tps: {first['prompt_tps']} tok/s ({'cached/reused' if first['prompt_rate_label'] == 'cached' else 'fresh'})")
print(f"  Last prompt tps: {last['prompt_tps']} tok/s ({'cached/reused' if last['prompt_rate_label'] == 'cached' else 'fresh'})")
print(f"  First load:      {first['load_s']} s")
print(f"  Last load:       {last['load_s']} s")
print(f"  First gen tps:   {first['generation_tps']} tok/s")
print(f"  Last gen tps:    {last['generation_tps']} tok/s")

if len(ok_results) >= 2:
    first_prompt = float(first["prompt_eval_s"])
    last_prompt = float(last["prompt_eval_s"])
    all_cached = all(r.get("prompt_rate_label") == "cached" for r in ok_results)
    if first_prompt > 0:
        ratio = last_prompt / first_prompt
        print(f"  Prompt ratio:    {ratio:.2f}x (last / first)")
        if all_cached:
            print("  Interpretation:  both runs appear warm and cache-friendly; this sample does not include a fresh prompt baseline.")
        elif ratio < 0.5:
            print("  Interpretation:  repeated runs showed a meaningful prompt-eval drop; prompt reuse or cache-hit behavior is likely.")
        elif ratio <= 1.2:
            print("  Interpretation:  repeated runs had similar prompt-eval cost; there is little evidence of cross-request prompt-prefix reuse.")
        else:
            print("  Interpretation:  repeated runs got slower; prompt reuse is not helping this scenario.")

    if any(r.get("prompt_rate_label") == "cached" for r in ok_results):
        print("  Cache note:      very high prompt tok/s on repeated runs is reported as cached/reused, not as fresh prompt-processing throughput.")
    else:
        print("  Cache note:      prompt tok/s values appear to reflect fresh prompt processing.")
    if first_prompt <= 0:
        print("  Interpretation:  first prompt-eval duration was zero or unavailable.")
else:
    print("  Interpretation:  run again with --runs 2 or more to compare cold-versus-warm behavior.")

print("")
print("Takeaway:")
first_ttft = float(first["ttft_s"])
last_ttft = float(last["ttft_s"])
first_load = float(first["load_s"])
first_prompt = float(first["prompt_eval_s"])
first_eval = float(first["eval_s"])
last_eval_tps = float(last["generation_tps"])

if first_load >= max(first_prompt, first_eval) and first_load >= 1.0:
    print(f"  Startup cost is dominated by model load. A cold first reply may wait about {first_ttft:.1f}s before text starts.")
elif first_prompt >= max(first_load, first_eval) and first_prompt >= 1.0:
    print(f"  Startup cost is dominated by prompt processing. Large fresh prompts may wait about {first_ttft:.1f}s before text starts.")
else:
    print(f"  Startup cost is relatively low here. The reply started in about {first_ttft:.1f}s.")

if any(r.get("prompt_rate_label") == "cached" for r in ok_results):
    print(f"  This run shows prompt reuse or cache-hit behavior. Once warm, similar prompts start responding in about {last_ttft:.1f}s.")
else:
    print(f"  This run does not show a strong prompt-cache win. Similar prompts may still take about {last_ttft:.1f}s to start.")

if last_eval_tps > 0:
    print(f"  Response generation is the steady-state limiter at about {last_eval_tps:.1f} tok/s once output begins.")
PY
}

main() {
  parse_args "$@"
  need_cmd curl
  need_cmd python3
  validate_args
  load_text_inputs

  TMP_PS="$(mktemp /tmp/ollama-benchmark-ps.XXXXXX)"

  local initial_loaded=""
  initial_loaded="$(fetch_loaded_state)"
  print_header "$initial_loaded"

  local request_json=""
  request_json="$(build_request_json)"

  local -a result_jsons=()
  local run=1
  while [[ "$run" -le "$RUNS" ]]; do
    local result_json=""
    result_json="$(run_single_request "$run" "$request_json")"
    result_jsons+=("$result_json")
    print_run_report "$result_json"
    printf '\n'
    run="$((run + 1))"
  done

  local results_json=""
  results_json="$(RESULT_LINES="$(printf '%s\n' "${result_jsons[@]}")" python3 - <<'PY'
import json
import os

items = [json.loads(line) for line in os.environ["RESULT_LINES"].splitlines() if line.strip()]
print(json.dumps(items))
PY
)"
  print_summary "$results_json"
}

main "$@"
