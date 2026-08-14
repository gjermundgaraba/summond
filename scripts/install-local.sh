#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/release.sh"
LOCAL_MODE=1
configure_artifact

TARGET_APP="/Applications/$APP_NAME"
BUILT_APP="$OUTPUT_DIR/$APP_NAME"
APP_PROCESS="$APP_PRODUCT_NAME"
STATUS_PROCESS="$STATUS_PRODUCT_NAME"
AGENT_LABEL="$AGENT_BUNDLE_IDENTIFIER"
AGENT_EXECUTABLE="$TARGET_APP/Contents/MacOS/$AGENT_APP_NAME/Contents/MacOS/$AGENT_PRODUCT_NAME"

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

refresh_services() {
  local pid
  "$TARGET_APP/Contents/MacOS/$APP_PROCESS" --refresh-services &
  pid=$!
  for _ in {1..600}; do
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

"$ROOT_DIR/scripts/release.sh" --local

[[ -d "$BUILT_APP" ]] || die "signed app was not produced at $BUILT_APP."

stage_dir="$(mktemp -d /Applications/.summond-local-install.XXXXXX)"
cleanup() {
  rm -rf -- "$stage_dir"
}
trap cleanup EXIT
ditto "$BUILT_APP" "$stage_dir/$APP_NAME"
codesign --verify --deep --strict --verbose=2 "$stage_dir/$APP_NAME"

pkill -x "$APP_PROCESS" 2>/dev/null || true
for _ in {1..50}; do
  pgrep -x "$APP_PROCESS" >/dev/null || break
  sleep 0.1
done
pgrep -x "$APP_PROCESS" >/dev/null && die "$APP_PROCESS did not quit."
pkill -x "$STATUS_PROCESS" 2>/dev/null || true

backup_dir=""
if [[ -d "$TARGET_APP" ]]; then
  trash_dir="${HOME:?}/.Trash"
  [[ -d "$trash_dir" ]] || die "Trash directory not found at $trash_dir."
  backup_dir="$(mktemp -d "$trash_dir/summond-local-install.XXXXXX")"
  mv "$TARGET_APP" "$backup_dir/$APP_NAME"
fi

if ! mv "$stage_dir/$APP_NAME" "$TARGET_APP"; then
  [[ -z "$backup_dir" ]] || mv "$backup_dir/$APP_NAME" "$TARGET_APP"
  die "could not move the signed app into /Applications."
fi

refresh_services \
  || die "the signed app was installed, but its services could not be refreshed. Previous app: $backup_dir/$APP_NAME"

agent_pid=""
if agent_state >/dev/null; then
  agent_pid="$(wait_for_agent_to_run || true)"
  [[ -n "$agent_pid" ]] \
    || die "the signed app was installed, but its enabled agent did not start from the new app. Previous app: $backup_dir/$APP_NAME"
fi

/usr/bin/open "$TARGET_APP"
if [[ -n "$agent_pid" ]]; then
  printf 'Installed %s; agent is running (pid %s).\n' "$TARGET_APP" "$agent_pid"
else
  printf 'Installed %s. Complete setup in the opened app.\n' "$TARGET_APP"
fi
[[ -z "$backup_dir" ]] || printf 'Previous app: %s\n' "$backup_dir/$APP_NAME"
