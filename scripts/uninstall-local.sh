#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/release.sh"
LOCAL_MODE=1
configure_artifact

TARGET_APP="/Applications/$APP_NAME"
INSTALLED_EXECUTABLE="$TARGET_APP/Contents/MacOS/$APP_PRODUCT_NAME"
APP_PROCESS="$APP_PRODUCT_NAME"

prepare_uninstall() {
  local pid
  "$INSTALLED_EXECUTABLE" --prepare-uninstall &
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
  printf 'error: uninstall preparation timed out.\n' >&2
  return 1
}

[[ "$(id -u)" -ne 0 ]] || die "do not run uninstall-local with sudo."
if [[ ! -d "$TARGET_APP" ]]; then
  printf '%s is not installed.\n' "$TARGET_APP"
  exit 0
fi

[[ -x "$INSTALLED_EXECUTABLE" ]] || die "installed executable not found at $INSTALLED_EXECUTABLE."

user_id="$(id -u)"
pkill -u "$user_id" -x "$APP_PROCESS" 2>/dev/null || true
for _ in {1..50}; do
  pgrep -u "$user_id" -x "$APP_PROCESS" >/dev/null || break
  sleep 0.1
done
pgrep -u "$user_id" -x "$APP_PROCESS" >/dev/null && die "$APP_PROCESS did not quit."

prepare_uninstall \
  || die "could not unregister the background service or menu bar item."

/usr/bin/trash --stopOnError "$TARGET_APP" \
  || die "could not move $TARGET_APP to the Trash; its services are unregistered."

printf 'Uninstalled %s. Saved local configuration and preferences were preserved.\n' \
  "$APP_PRODUCT_NAME"
