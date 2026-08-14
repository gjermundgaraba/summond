#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s LAUNCH_AGENT_PLIST TEAM_ID SIGNING_IDENTIFIER\n' "$0" >&2
}

if [[ $# -ne 3 ]]; then
  usage
  exit 64
fi

agent_plist="$1"
team_id="$2"
signing_identifier="$3"

[[ -n "$team_id" ]] || exit 0
[[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] || {
  printf 'error: TEAM_ID must be 10 uppercase letters or digits\n' >&2
  exit 64
}
[[ -f "$agent_plist" ]] || {
  printf 'error: LaunchAgent plist not found at %s\n' "$agent_plist" >&2
  exit 1
}

/usr/libexec/PlistBuddy -c "Delete :SpawnConstraint" "$agent_plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :SpawnConstraint dict" "$agent_plist"
/usr/libexec/PlistBuddy -c "Add :SpawnConstraint:team-identifier string $team_id" "$agent_plist"
/usr/libexec/PlistBuddy -c \
  "Add :SpawnConstraint:signing-identifier string $signing_identifier" \
  "$agent_plist"
