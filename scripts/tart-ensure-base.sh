#!/usr/bin/env bash
set -euo pipefail

base_vm="${1:-summond-macos-tahoe-xcodegen-base}"
source_image="${SUMMOND_TART_SOURCE_IMAGE:-ghcr.io/cirruslabs/macos-tahoe-xcode:latest}"
ready_timeout=300
run_pid=""
started_vm=0

usage() {
  echo "usage: $0 [base-vm]" >&2
}

cleanup() {
  local status=$?
  if [[ "$started_vm" == "1" ]]; then
    tart stop "$base_vm" >/dev/null 2>&1 || true
    if [[ -n "$run_pid" ]]; then
      wait "$run_pid" >/dev/null 2>&1 || true
    fi
  fi
  exit "$status"
}
trap cleanup EXIT

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if ! command -v tart >/dev/null 2>&1; then
  echo "tart is required for $0" >&2
  exit 127
fi

wait_for_guest() {
  local deadline=$((SECONDS + ready_timeout))
  until tart exec "$base_vm" /usr/bin/true >/dev/null 2>&1; do
    if [[ "$started_vm" == "1" ]] && ! kill -0 "$run_pid" >/dev/null 2>&1; then
      wait "$run_pid" || true
      echo "Tart VM '$base_vm' exited before the guest agent was ready." >&2
      exit 1
    fi
    if (( SECONDS >= deadline )); then
      echo "Timed out waiting for Tart Guest Agent in '$base_vm'." >&2
      exit 1
    fi
    sleep 5
  done
}

vm_is_running() {
  [[ "$(tart get "$base_vm" --format json | plutil -extract Running raw -o - -)" == "true" ]]
}

if tart get "$base_vm" --format json >/dev/null 2>&1; then
  echo "Using existing Tart base VM '$base_vm'."
  if vm_is_running; then
    echo "Stopping base VM '$base_vm' before cloning from it..."
    tart stop "$base_vm"
  fi
  exit 0
fi

echo "Creating Tart base VM '$base_vm' from '$source_image'..."
tart clone "$source_image" "$base_vm"

echo "Starting '$base_vm' to install base tools..."
tart run "$base_vm" &
run_pid=$!
started_vm=1
wait_for_guest

tart exec "$base_vm" /bin/zsh -lc \
  'set -euo pipefail
   if ! command -v xcodebuild >/dev/null 2>&1; then
     echo "xcodebuild is not available in this Tart image." >&2
     exit 1
   fi
   if ! command -v xcodegen >/dev/null 2>&1; then
     if ! command -v brew >/dev/null 2>&1; then
       echo "Homebrew is required to install xcodegen in the base VM." >&2
       exit 1
     fi
     HOMEBREW_NO_AUTO_UPDATE=1 brew install xcodegen
   fi
   xcodebuild -version
   xcodegen --version
   # tart stop powers off the VM before macOS necessarily flushes recent writes.
   # Persist Homebrew installs before cleanup stops the base VM.
   /bin/sync'

echo "Base VM '$base_vm' is ready."
