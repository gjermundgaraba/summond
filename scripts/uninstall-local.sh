#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_APP="/Applications/Summond.app"
BUILT_APP="$ROOT_DIR/dist/release/Summond.app"
BUILT_EXECUTABLE="$BUILT_APP/Contents/MacOS/Summond"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

prepare_uninstall() {
  local pid
  "$BUILT_EXECUTABLE" --prepare-uninstall &
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

installed_details="$(codesign -dvv "$TARGET_APP" 2>&1 || true)"
signing_identity="${SIGNING_IDENTITY:-$(awk -F= '/^Authority=/{print $2; exit}' <<<"$installed_details")}"
team_id="${TEAM_ID:-$(awk -F= '/^TeamIdentifier=/{print $2; exit}' <<<"$installed_details")}"
[[ -n "$signing_identity" ]] || die "could not determine the installed app's signing identity."
[[ -n "$team_id" ]] || die "could not determine the installed app's team id."

helper_details="$(codesign -dvv "$BUILT_APP" 2>&1 || true)"
helper_team_id="$(awk -F= '/^TeamIdentifier=/{print $2; exit}' <<<"$helper_details")"
if [[ ! -x "$BUILT_EXECUTABLE" || "$helper_team_id" != "$team_id" ]] \
  || ! grep -aFq -- '--prepare-uninstall' "$BUILT_EXECUTABLE"
then
  printf 'Building the signed uninstall helper…\n'
  SIGNING_IDENTITY="$signing_identity" TEAM_ID="$team_id" \
    "$ROOT_DIR/scripts/release.sh" --local
fi
[[ -x "$BUILT_EXECUTABLE" ]] || die "signed app was not produced at $BUILT_APP."

user_id="$(id -u)"
pkill -u "$user_id" -x Summond 2>/dev/null || true
for _ in {1..50}; do
  pgrep -u "$user_id" -x Summond >/dev/null || break
  sleep 0.1
done
pgrep -u "$user_id" -x Summond >/dev/null && die "Summond did not quit."

prepare_uninstall \
  || die "could not unregister the background service or menu bar item."

/usr/bin/trash --stopOnError "$TARGET_APP" \
  || die "could not move $TARGET_APP to the Trash; its services are unregistered."

printf 'Uninstalled Summond. Saved configuration and preferences were preserved.\n'
