#!/usr/bin/env bash
# Runs inside the Tart VM: build an ad-hoc SMOKE_TEST app, bootstrap its embedded
# agent directly with launchctl, then round-trip agent status over the mach service.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

app="dist/release/Summond.app"
source_plist="App/Resources/net.garaba.summond.agent.plist"
label="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$source_plist")"
domain="gui/$(id -u)"
result="$(mktemp "${TMPDIR:-/tmp}/summond-smoke.XXXXXX")"
plist="$(mktemp "${TMPDIR:-/tmp}/summond-smoke-agent.XXXXXX").plist"

cleanup() {
  launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
  rm -f "$result" "$plist"
}
trap cleanup EXIT

echo "==> Building ad-hoc-signed SMOKE_TEST Release app"
scripts/release.sh --smoke

shipped_plist="$app/Contents/Library/LaunchAgents/$label.plist"
[[ -f "$shipped_plist" ]] || {
  echo "error: LaunchAgent plist not found at $shipped_plist" >&2
  exit 1
}

cp "$shipped_plist" "$plist"
bundle_program="$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$plist")"
agent_bin="$app/$bundle_program"
[[ -x "$ROOT_DIR/$agent_bin" ]] || {
  echo "error: agent binary not found at $agent_bin" >&2
  exit 1
}

echo "==> Generating a launchctl-loadable agent plist (absolute Program)"
/usr/libexec/PlistBuddy -c 'Delete :BundleProgram' "$plist"
/usr/libexec/PlistBuddy -c "Add :Program string $ROOT_DIR/$agent_bin" "$plist"

echo "==> Bootstrapping the agent into $domain"
launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
launchctl bootstrap "$domain" "$plist"

echo "==> Running the XPC-only smoke (client connects + status round-trip)"
# `open -W` runs the client in the GUI session so it shares the agent's mach
# bootstrap namespace, and waits for it to exit. The result is read from the file
# because `open` does not propagate the launched app's exit code.
open -W "$app" --args --smoke-output "$result"

echo "==> Smoke result:"
cat "$result" 2>/dev/null || true
grep -q '^smoke: ok' "$result"
echo "==> Smoke test passed"
