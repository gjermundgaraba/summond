#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
base_vm="${1:-codex-macos-tahoe-xcodegen-base}"
job="${2:-test}"
run_vm=""

usage() {
  echo "usage: $0 [base-vm] [job]   # job: test (default) | smoke" >&2
}

cleanup() {
  local status=$?
  if [[ -n "$run_vm" ]]; then
    tart stop "$run_vm" >/dev/null 2>&1 || true
    tart delete "$run_vm" >/dev/null 2>&1 || true
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

"$SCRIPT_DIR/tart-ensure-base.sh" "$base_vm"

safe_base_name="$(printf '%s' "$base_vm" | tr -c '[:alnum:]._-' '-')"
run_vm="${safe_base_name}-run-$(date +%Y%m%d-%H%M%S)-$$"

echo "Cloning clean Tart VM '$run_vm' from base '$base_vm'..."
tart clone "$base_vm" "$run_vm"

"$SCRIPT_DIR/tart-test-vm.sh" "$run_vm" "$job"
