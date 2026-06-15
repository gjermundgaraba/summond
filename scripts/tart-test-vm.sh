#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
vm="${1:-}"
guest_repo="/Volumes/My Shared Files/summond"
ready_timeout=300
started_vm=0
run_pid=""

usage() {
  echo "usage: $0 <tart-vm>" >&2
}

cleanup() {
  local status=$?
  if [[ "$started_vm" == "1" ]]; then
    tart stop "$vm" >/dev/null 2>&1 || true
    if [[ -n "$run_pid" ]]; then
      wait "$run_pid" >/dev/null 2>&1 || true
    fi
  fi
  exit "$status"
}
trap cleanup EXIT

if [[ -z "$vm" ]]; then
  usage
  exit 64
fi

if ! command -v tart >/dev/null 2>&1; then
  echo "tart is required for $0" >&2
  exit 127
fi

if ! tart get "$vm" --format json >/dev/null 2>&1; then
  echo "Tart VM '$vm' does not exist." >&2
  exit 1
fi

wait_for_repo() {
  local deadline=$((SECONDS + ready_timeout))
  until tart exec "$vm" /bin/test -f "$guest_repo/Makefile" >/dev/null 2>&1; do
    if [[ "$started_vm" == "1" ]] && ! kill -0 "$run_pid" >/dev/null 2>&1; then
      wait "$run_pid" || true
      echo "Tart VM '$vm' exited before the summond checkout was available." >&2
      exit 1
    fi
    if [[ "$started_vm" != "1" ]] && tart exec "$vm" /usr/bin/true >/dev/null 2>&1; then
      echo "Tart VM '$vm' is already running without the summond checkout mounted." >&2
      echo "Stop it and rerun this command so the checkout can be mounted." >&2
      exit 1
    fi
    if (( SECONDS >= deadline )); then
      echo "Timed out waiting for '$guest_repo' in Tart VM '$vm'." >&2
      echo "If the VM was already running, stop it and rerun this command so the checkout can be mounted." >&2
      exit 1
    fi
    sleep 5
  done
}

vm_is_running() {
  [[ "$(tart get "$vm" --format json | plutil -extract Running raw -o - -)" == "true" ]]
}

if tart exec "$vm" /bin/test -f "$guest_repo/Makefile" >/dev/null 2>&1; then
  echo "Using already-running Tart VM '$vm'."
elif vm_is_running; then
  echo "Waiting for already-running Tart VM '$vm' to expose the summond checkout..."
  wait_for_repo
else
  echo "Starting Tart VM '$vm' with the summond checkout mounted..."
  tart run --dir "summond:$ROOT_DIR" "$vm" &
  run_pid=$!
  started_vm=1
  wait_for_repo
fi

tart exec "$vm" /bin/zsh -lc \
  'set -euo pipefail
   run_root="$(mktemp -d "${TMPDIR:-/tmp}/summond-test.XXXXXX")"
   trap '\''rm -rf "$run_root"'\'' EXIT
   /usr/bin/rsync -a --delete \
     --exclude ".build" \
     --exclude ".git" \
     --exclude ".swiftpm" \
     "/Volumes/My Shared Files/summond/" "$run_root/checkout/"
   cd "$run_root/checkout"
   ALLOW_HOST_UITESTS=1 make test ui-test'
