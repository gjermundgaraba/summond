#!/usr/bin/env bash
set -euo pipefail

TARGET_APP="/Applications/Summond.app"
EXECUTABLE="$TARGET_APP/Contents/MacOS/Summond"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

prepare_uninstall() {
  local pid
  "$EXECUTABLE" --prepare-uninstall >/dev/null 2>&1 &
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

if [[ ! -d "$TARGET_APP" ]]; then
  printf '%s is not installed.\n' "$TARGET_APP"
  exit 0
fi
[[ -x "$EXECUTABLE" ]] || die "installed app executable not found at $EXECUTABLE."

pkill -x Summond 2>/dev/null || true
for _ in {1..50}; do
  pgrep -x Summond >/dev/null || break
  sleep 0.1
done
pgrep -x Summond >/dev/null && die "Summond did not quit."

prepare_uninstall \
  || die "could not unregister services; run make install-local once if the installed app predates uninstall-local."

trash_dir="${HOME:?}/.Trash"
[[ -d "$trash_dir" ]] || die "Trash directory not found at $trash_dir."
trashed_app_dir="$(mktemp -d "$trash_dir/summond-uninstall.XXXXXX")"
if ! mv "$TARGET_APP" "$trashed_app_dir/Summond.app"; then
  rmdir "$trashed_app_dir"
  die "could not move $TARGET_APP to the Trash."
fi

printf 'Uninstalled Summond. Saved configuration and preferences were preserved.\n'
printf 'Trashed app: %s\n' "$trashed_app_dir/Summond.app"
