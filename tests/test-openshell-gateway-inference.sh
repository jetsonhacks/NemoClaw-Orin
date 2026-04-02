#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/script-ui.sh"

SANDBOX_NAME=""
EXPECTED_REPLY="${EXPECTED_REPLY:-OpenShell gateway inference test passed.}"
TEST_MESSAGE="${TEST_MESSAGE:-Reply with exactly this text and nothing else: OpenShell gateway inference test passed.}"
SYSTEM_MESSAGE="${SYSTEM_MESSAGE:-You are a concise test assistant.}"
MAX_TOKENS="${MAX_TOKENS:-120}"
TEMPERATURE="${TEMPERATURE:-0}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-60}"

usage() {
  cat <<'EOF_USAGE'
Usage:
  ./tests/test-openshell-gateway-inference.sh <sandbox-name> [options]

Options:
  --message TEXT        User message to send to the provider
  --expected TEXT       Exact reply expected from the provider
  --system TEXT         System prompt to include in the request
  --max-tokens N        Max completion tokens (default: 120)
  --temperature VALUE   Sampling temperature (default: 0)
  --timeout SECONDS     Curl timeout inside the sandbox (default: 60)
  -h, --help            Show this help

Notes:
  - This script runs the probe through the OpenShell SSH path for the sandbox.
  - It targets https://inference.local/v1/chat/completions inside the sandbox.
  - The active provider and model come from `openshell inference get`.
EOF_USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --message)
        [[ $# -ge 2 ]] || die "Missing value for --message"
        TEST_MESSAGE="$2"
        shift 2
        ;;
      --expected)
        [[ $# -ge 2 ]] || die "Missing value for --expected"
        EXPECTED_REPLY="$2"
        shift 2
        ;;
      --system)
        [[ $# -ge 2 ]] || die "Missing value for --system"
        SYSTEM_MESSAGE="$2"
        shift 2
        ;;
      --max-tokens)
        [[ $# -ge 2 ]] || die "Missing value for --max-tokens"
        MAX_TOKENS="$2"
        shift 2
        ;;
      --temperature)
        [[ $# -ge 2 ]] || die "Missing value for --temperature"
        TEMPERATURE="$2"
        shift 2
        ;;
      --timeout)
        [[ $# -ge 2 ]] || die "Missing value for --timeout"
        REQUEST_TIMEOUT="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        if [[ -z "$SANDBOX_NAME" ]]; then
          SANDBOX_NAME="$1"
        else
          die "Unexpected extra argument: $1"
        fi
        shift
        ;;
    esac
  done

  [[ -n "$SANDBOX_NAME" ]] || die "Usage: $0 <sandbox-name>"
}

sandbox_ssh_command() {
  local sandbox_name="$1"
  shift
  local cmd="$*"
  local openshell_bin
  openshell_bin="$(command -v openshell)"
  ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o "ProxyCommand=${openshell_bin} ssh-proxy --gateway-name ${GATEWAY_NAME} --name ${sandbox_name}" \
    "sandbox@openshell-${sandbox_name}" \
    "${cmd}"
}

ssh_env_prefix() {
  cat <<'EOF_ENV'
export HOME=/sandbox
EOF_ENV
}

capture_command() {
  local __outvar="$1"
  shift

  local output=""
  local rc=0
  set +e
  output="$("$@" 2>&1)"
  rc=$?
  set -e

  printf -v "$__outvar" '%s' "$output"
  return "$rc"
}

get_active_provider_and_model() {
  local inference_output
  inference_output="$(openshell inference get 2>/dev/null || true)"

  python3 - "$inference_output" <<'PY'
import re
import sys

text = sys.argv[1]
text = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', text)
provider = ''
model = ''
capturing = False

for line in text.splitlines():
    stripped = line.strip()
    if 'Gateway inference:' in stripped:
        capturing = True
        continue
    if 'System inference:' in stripped and capturing:
        break
    if not capturing:
        continue
    if stripped.startswith('Provider:'):
        provider = stripped.split(':', 1)[1].strip()
    elif stripped.startswith('Model:'):
        model = stripped.split(':', 1)[1].strip()

print(provider)
print(model)
PY
}

build_request_payload() {
  python3 - "$SYSTEM_MESSAGE" "$TEST_MESSAGE" "$1" "$2" <<'PY'
import json
import sys

system_message = sys.argv[1]
user_message = sys.argv[2]
temperature = float(sys.argv[3])
max_tokens = int(sys.argv[4])

payload = {
    "model": None,
    "messages": [
        {"role": "system", "content": system_message},
        {"role": "user", "content": user_message},
    ],
    "temperature": temperature,
    "max_tokens": max_tokens,
}

print(json.dumps(payload))
PY
}

run_remote_inference_probe() {
  local model_name="$1"
  local payload_json="$2"

  sandbox_ssh_command "$SANDBOX_NAME" "MODEL_NAME=$(printf '%q' "$model_name") PAYLOAD_JSON=$(printf '%q' "$payload_json") REQUEST_TIMEOUT=$(printf '%q' "$REQUEST_TIMEOUT") sh -s" <<'EOF_REMOTE'
set -eu
export HOME=/sandbox

tmp_body="/tmp/openshell-inference-body.$$"
tmp_err="/tmp/openshell-inference-err.$$"
trap 'rm -f "$tmp_body" "$tmp_err"' EXIT

tmp_request="/tmp/openshell-inference-request.$$"

python3 - "$PAYLOAD_JSON" "$MODEL_NAME" >"$tmp_request" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
payload["model"] = sys.argv[2]
print(json.dumps(payload))
PY

set +e
http_code="$(curl \
  --silent \
  --show-error \
  --output "$tmp_body" \
  --write-out '%{http_code}' \
  --max-time "$REQUEST_TIMEOUT" \
  --insecure \
  -H 'Content-Type: application/json' \
  -d @"$tmp_request" \
  https://inference.local/v1/chat/completions 2>"$tmp_err")"
curl_exit="$?"
set -e

printf '__CURL_EXIT__=%s\n' "$curl_exit"
printf '__HTTP_STATUS__=%s\n' "${http_code:-000}"
printf '__BODY_BASE64__='
base64 <"$tmp_body" | tr -d '\n'
printf '\n'
printf '__STDERR_BASE64__='
base64 <"$tmp_err" | tr -d '\n'
printf '\n'
rm -f "$tmp_request"
EOF_REMOTE
}

decode_probe_output() {
  python3 - "$1" <<'PY'
import base64
import json
import sys

raw = sys.argv[1]
data = {}
for line in raw.splitlines():
    if "=" not in line or not line.startswith("__"):
        continue
    key, value = line.split("=", 1)
    data[key] = value

body = base64.b64decode(data.get("__BODY_BASE64__", "") or b"").decode("utf-8", "replace")
stderr = base64.b64decode(data.get("__STDERR_BASE64__", "") or b"").decode("utf-8", "replace")

print(json.dumps({
    "curl_exit": int(data.get("__CURL_EXIT__", "1")),
    "http_status": data.get("__HTTP_STATUS__", "000"),
    "body": body,
    "stderr": stderr,
}, indent=2))
PY
}

render_probe_result() {
  python3 - "$1" "$2" "$3" "$4" "$TEST_MESSAGE" "$EXPECTED_REPLY" <<'PY'
import json
import sys

probe = json.loads(sys.argv[1])
provider = sys.argv[2]
model = sys.argv[3]
sandbox = sys.argv[4]
message = sys.argv[5]
expected_reply = sys.argv[6]

curl_exit = probe["curl_exit"]
http_status = str(probe["http_status"])
body = probe["body"]
stderr = probe["stderr"].strip()
normalized_expected = expected_reply.strip()

ok = False
summary = ""
assistant_text = ""
finish_reason = ""
raw_error = ""
mismatch_note = ""
display_answer = ""

if curl_exit != 0:
    summary = "The sandbox could not reach inference.local or complete the HTTPS request."
elif not http_status.startswith("2"):
    summary = f"The provider returned HTTP {http_status}."
else:
    try:
        response = json.loads(body)
    except json.JSONDecodeError:
        summary = "The provider returned a non-JSON response."
    else:
        choices = response.get("choices") or []
        if choices:
            message_obj = choices[0].get("message") or {}
            assistant_text = message_obj.get("content") or ""
            finish_reason = choices[0].get("finish_reason") or ""
            normalized_answer = assistant_text.strip()
            display_answer = normalized_answer or assistant_text
            if normalized_answer == normalized_expected:
                ok = True
                summary = "Gateway inference call succeeded and matched the expected reply."
            else:
                summary = "Gateway inference call succeeded, but the provider answer did not match the expected reply."
                mismatch_note = f"Expected exactly: {expected_reply}"
        else:
            error_obj = response.get("error") or {}
            raw_error = error_obj.get("message") or body.strip()
            summary = "The provider response did not contain a completion choice."

if not display_answer:
    if raw_error:
        display_answer = raw_error
    elif body.strip():
        display_answer = body.strip()
    else:
        display_answer = "<no response body>"

print(f"OpenShell gateway inference test")
print("")
print(f"Sandbox:   {sandbox}")
print(f"Provider:  {provider or '<unknown>'}")
print(f"Model:     {model or '<unknown>'}")
print(f"Prompt:    Reply with exactly this text and nothing else: \"{expected_reply}\"")
print(f"Expected:  {expected_reply}")
print(f"Returned:  {display_answer}")
print("")
print(f"Correct:   {'YES' if ok else 'NO'}")

print("")
print("DETAILS:")
print(f"HTTP:      {http_status}")
print(f"Result:    {'PASS' if ok else 'FAIL'}")
print(f"Why:       {summary}")

if assistant_text.strip():
    print("")
    print("Provider answer:")
    print(assistant_text.strip())
elif raw_error:
    print("")
    print("Provider error:")
    print(raw_error)
elif body.strip():
    print("")
    print("Raw response:")
    print(body.strip())

if mismatch_note:
    print("")
    print("Mismatch:")
    print(mismatch_note)

if finish_reason:
    print("")
    print(f"Finish:    {finish_reason}")

if stderr:
    print("")
    print("Transport notes:")
    print(stderr)

sys.exit(0 if ok else 1)
PY
}

main() {
  parse_args "$@"

  need_cmd openshell
  need_cmd ssh
  need_cmd python3

  ui_step "Checking OpenShell gateway state"
  openshell status >/dev/null 2>&1 || \
    die "OpenShell gateway is not reachable. Run onboarding or restart recovery first."

  local -a active_pm=()
  local provider_name=""
  local model_name=""
  mapfile -t active_pm < <(get_active_provider_and_model)
  provider_name="${active_pm[0]:-}"
  model_name="${active_pm[1]:-}"

  [[ -n "$provider_name" ]] || die "No active gateway provider is configured. Run ./providers/configure-gateway-provider.sh first."
  [[ -n "$model_name" ]] || die "No active gateway model is configured. Run ./providers/configure-gateway-provider.sh --model <name> --activate first."

  ui_step "Sending test message through inference.local from sandbox '$SANDBOX_NAME'"
  local payload_json=""
  payload_json="$(build_request_payload "$TEMPERATURE" "$MAX_TOKENS")"

  local remote_output=""
  if ! capture_command remote_output run_remote_inference_probe "$model_name" "$payload_json"; then
    printf 'OpenShell gateway inference test\n\n' \
      && printf 'Result:    FAIL\n' \
      && printf 'Why:       Could not establish the OpenShell SSH session for sandbox %s.\n' "$SANDBOX_NAME" \
      && [[ -n "$remote_output" ]] && printf '\nTransport notes:\n%s\n' "$remote_output"
    exit 1
  fi

  local decoded_probe=""
  decoded_probe="$(decode_probe_output "$remote_output")"
  render_probe_result "$decoded_probe" "$provider_name" "$model_name" "$SANDBOX_NAME"
}

main "$@"
