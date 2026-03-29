#!/usr/bin/env bash

SANDBOX_KEXEC_RETRIES="${SANDBOX_KEXEC_RETRIES:-5}"
SANDBOX_KEXEC_RETRY_DELAY="${SANDBOX_KEXEC_RETRY_DELAY:-2}"
SANDBOX_CONTAINER_NAME="${SANDBOX_CONTAINER_NAME:-}"

resolve_sandbox_container_name() {
  local sandbox_name="$1"

  if [[ -n "$SANDBOX_CONTAINER_NAME" ]]; then
    printf '%s\n' "$SANDBOX_CONTAINER_NAME"
    return 0
  fi

  local names_raw
  if ! names_raw="$(docker exec "$CONTAINER_NAME" kubectl get pod -n "$SANDBOX_NAMESPACE" "$sandbox_name" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)"; then
    printf 'Could not determine container list for sandbox pod %s\n' "$sandbox_name" >&2
    return 1
  fi

  # Split the jsonpath output on whitespace into an array.
  local names=()
  local name
  for name in $names_raw; do
    [[ -n "$name" ]] && names+=("$name")
  done

  case "${#names[@]}" in
    0)
      printf 'Sandbox pod %s has no regular containers.\n' "$sandbox_name" >&2
      return 1
      ;;
    1)
      printf '%s\n' "${names[0]}"
      return 0
      ;;
    *)
      printf 'Sandbox pod %s has multiple containers: %s\n' "$sandbox_name" "${names[*]}" >&2
      printf 'Set SANDBOX_CONTAINER_NAME to choose one explicitly.\n' >&2
      return 1
      ;;
  esac
}

sandbox_kexec() {
  local sandbox_name="$1"
  shift

  local target_container
  target_container="$(resolve_sandbox_container_name "$sandbox_name")" || return 1

  local attempt=1
  local output=""
  local rc=0

  while (( attempt <= SANDBOX_KEXEC_RETRIES )); do
    output="$(
      docker exec "$CONTAINER_NAME" kubectl exec \
        -n "$SANDBOX_NAMESPACE" \
        -c "$target_container" \
        "$sandbox_name" -- "$@" 2>&1
    )"
    rc=$?

    if [[ $rc -eq 0 ]]; then
      printf '%s' "$output"
      return 0
    fi

    if printf '%s\n' "$output" | grep -qiE 'unable to upgrade connection|container not found|pod does not exist|not found'; then
      if (( attempt < SANDBOX_KEXEC_RETRIES )); then
        sleep "$SANDBOX_KEXEC_RETRY_DELAY"
        attempt=$((attempt + 1))
        continue
      fi
    fi

    printf '%s\n' "$output" >&2
    return "$rc"
  done

  printf '%s\n' "$output" >&2
  return "$rc"
}