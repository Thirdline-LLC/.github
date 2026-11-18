#!/usr/bin/env bash
# One runner slot, forever (docs/progress.md, A5b): get a single-use runner config, run one job
# in a fresh container, let the container be deleted, repeat. Started by
# thirdline-runner@<slot>.service; reads the slot's limits from /etc/thirdline-runners/slots/<slot>.env
# (RUNNER_CPUS, RUNNER_MEMORY, RUNNER_IMAGE besides what jit-config.sh reads).
set -euo pipefail

CONF=/etc/thirdline-runners
BIN=/opt/thirdline-runners
slot=${1:?usage: supervise.sh <slot>}
# shellcheck source=/dev/null
source "$CONF/slots/$slot.env"
: "${RUNNER_CPUS:?}" "${RUNNER_MEMORY:?}" "${RUNNER_IMAGE:?}"
name="tr-$slot"
backoff=30

while :; do
  # A container left from a crash would block the name.
  docker rm -f "$name" > /dev/null 2>&1 || true

  if ! jit=$("$BIN/jit-config.sh" "$slot"); then
    echo "no runner config; retrying in ${backoff}s"
    sleep "$backoff"
    backoff=$(( backoff * 2 > 600 ? 600 : backoff * 2 ))
    continue
  fi
  backoff=30

  # The config goes in through a root-only env file, never on a command line where ps shows it.
  env_file=$(mktemp)
  chmod 600 "$env_file"
  printf 'JIT=%s\n' "$jit" > "$env_file"
  unset jit

  # One job, then the container is gone. No --privileged, no host Docker socket, the App key is
  # never mounted. Chromium's own sandbox needs privileges a container doesn't get, so jobs run
  # it with chromiumSandbox: false; the container is the sandbox.
  set +e
  docker run --rm --name "$name" \
    --cpuset-cpus "$RUNNER_CPUS" --memory "$RUNNER_MEMORY" --memory-swap "$RUNNER_MEMORY" \
    --pids-limit 4096 --shm-size 1g --security-opt no-new-privileges \
    --env-file "$env_file" \
    "$RUNNER_IMAGE" \
    bash -c 'j=$JIT; unset JIT; exec ./run.sh --jitconfig "$j"'
  status=$?
  set -e
  rm -f "$env_file"
  echo "slot $slot: runner exited with $status"
  # A runner that dies straight away (bad image, Docker down) must not spin.
  [ "$status" -eq 0 ] || sleep 15
done
