#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_APP="/Applications/Summond.app"
BUILT_APP="$ROOT_DIR/dist/release/Summond.app"
AGENT_LABEL="net.garaba.summond.agent"
AGENT_EXECUTABLE="$TARGET_APP/Contents/MacOS/SummondAgent.app/Contents/MacOS/SummondAgent"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

agent_state() {
  launchctl print "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null
}

wait_for_agent_to_run() {
  local state pid executable
  for _ in {1..100}; do
    state="$(agent_state || true)"
    if [[ "$state" == *$'state = running'* && "$state" == *$'pid ='* ]]; then
      pid="$(awk '/pid =/{print $3; exit}' <<<"$state")"
      executable="$(/usr/sbin/lsof -a -p "$pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
      if [[ "$executable" == "$AGENT_EXECUTABLE" ]]; then
        printf '%s\n' "$pid"
        return 0
      fi
    fi
    sleep 0.1
  done
  return 1
}

run_service_command() {
  local executable="$1/Contents/MacOS/Summond"
  local argument="$2"
  local pid
  "$executable" "$argument" >/dev/null 2>&1 &
  pid=$!
  for _ in {1..150}; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid"
      return
    fi
    sleep 0.1
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return 1
}

installed_details=""
if [[ -d "$TARGET_APP" ]]; then
  installed_details="$(codesign -dvv "$TARGET_APP" 2>&1 || true)"
fi

signing_identity="${SIGNING_IDENTITY:-$(awk -F= '/^Authority=/{print $2; exit}' <<<"$installed_details")}"
team_id="${TEAM_ID:-$(awk -F= '/^TeamIdentifier=/{print $2; exit}' <<<"$installed_details")}"
[[ -n "$signing_identity" ]] || die "set SIGNING_IDENTITY for the first local install."
[[ -n "$team_id" ]] || die "set TEAM_ID for the first local install."

SIGNING_IDENTITY="$signing_identity" TEAM_ID="$team_id" \
  "$ROOT_DIR/scripts/release.sh" --local

[[ -d "$BUILT_APP" ]] || die "signed app was not produced at $BUILT_APP."

agent_was_registered=0
agent_state >/dev/null && agent_was_registered=1

stage_dir="$(mktemp -d /Applications/.summond-install.XXXXXX)"
cleanup() {
  rm -rf -- "$stage_dir"
}
trap cleanup EXIT
ditto "$BUILT_APP" "$stage_dir/Summond.app"
codesign --verify --deep --strict --verbose=2 "$stage_dir/Summond.app"

pkill -x Summond 2>/dev/null || true
for _ in {1..50}; do
  pgrep -x Summond >/dev/null || break
  sleep 0.1
done
pgrep -x Summond >/dev/null && die "Summond did not quit."
pkill -x SummondStatus 2>/dev/null || true

backup_dir=""
if [[ -d "$TARGET_APP" ]]; then
  trash_dir="${HOME:?}/.Trash"
  [[ -d "$trash_dir" ]] || die "Trash directory not found at $trash_dir."
  backup_dir="$(mktemp -d "$trash_dir/summond-install.XXXXXX")"
  mv "$TARGET_APP" "$backup_dir/Summond.app"
fi

if ! mv "$stage_dir/Summond.app" "$TARGET_APP"; then
  [[ -z "$backup_dir" ]] || mv "$backup_dir/Summond.app" "$TARGET_APP"
  die "could not move the signed app into /Applications."
fi

if [[ "$agent_was_registered" -eq 1 ]]; then
  agent_pid=""
  for delay in 0.5 2 5; do
    sleep "$delay"
    run_service_command "$TARGET_APP" --restart-agent || true
    agent_pid="$(wait_for_agent_to_run || true)"
    [[ -n "$agent_pid" ]] && break
  done
  [[ -n "$agent_pid" ]] \
    || die "the signed app was installed, but its agent did not start. Previous app: $backup_dir/Summond.app"

  /usr/bin/open "$TARGET_APP"
  printf 'Installed %s; agent is running (pid %s).\n' "$TARGET_APP" "$agent_pid"
  [[ -z "$backup_dir" ]] || printf 'Previous app: %s\n' "$backup_dir/Summond.app"
  exit 0
fi

/usr/bin/open "$TARGET_APP"
printf 'Installed %s. Complete setup in the opened app.\n' "$TARGET_APP"
