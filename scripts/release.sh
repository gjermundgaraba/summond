#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/release.sh [--local|--smoke] [options]

Build, sign, verify, package, and notarize Summond.app.

Modes:
  default release mode
      Requires a Developer ID Application identity, TEAM_ID, and a notarytool
      keychain profile. Verification and notarization failures are fatal.

  --local
      Signs with the requested identity, skips notarization, and reports
      Gatekeeper assessment failures without aborting. Signing identity
      mismatches remain fatal. This is intended for Apple Development
      identities and local plumbing checks.

  --smoke
      Builds the SMOKE_TEST entry point, signs ad-hoc, and skips notarization.
      Used by scripts/smoke-in-vm.sh / make smoke-tart.

Options:
  --identity NAME          Signing identity. Default: SIGNING_IDENTITY env or
                           "Developer ID Application".
  --team-id TEAM_ID        Apple Developer Team ID. Default: TEAM_ID env.
  --notary-profile NAME    notarytool keychain profile. Default:
                           NOTARY_PROFILE env.
  --output-dir DIR         Output directory. Default: OUTPUT_DIR env or
                           dist/release.
  --help                   Show this help.

Environment:
  SIGNING_IDENTITY         Same as --identity.
  TEAM_ID                  Same as --team-id.
  NOTARY_PROFILE           Same as --notary-profile.
  OUTPUT_DIR               Same as --output-dir.
USAGE
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/.build/release-dd"
PROJECT_PATH="$ROOT_DIR/Summond.xcodeproj"
SCHEME="Summond"
CONFIGURATION="Release"
APP_NAME="Summond.app"

LOCAL_MODE=0
SMOKE_MODE=0
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application}"
TEAM_ID="${TEAM_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist/release}"

log() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

parse_args() {
  while (($#)); do
    case "$1" in
      --local)
        LOCAL_MODE=1
        shift
        ;;
      --smoke)
        SMOKE_MODE=1
        LOCAL_MODE=1
        shift
        ;;
      --identity)
        [[ $# -ge 2 ]] || die "--identity requires a value"
        SIGNING_IDENTITY="$2"
        shift 2
        ;;
      --identity=*)
        SIGNING_IDENTITY="${1#*=}"
        shift
        ;;
      --team-id)
        [[ $# -ge 2 ]] || die "--team-id requires a value"
        TEAM_ID="$2"
        shift 2
        ;;
      --team-id=*)
        TEAM_ID="${1#*=}"
        shift
        ;;
      --notary-profile)
        [[ $# -ge 2 ]] || die "--notary-profile requires a value"
        NOTARY_PROFILE="$2"
        shift 2
        ;;
      --notary-profile=*)
        NOTARY_PROFILE="${1#*=}"
        shift
        ;;
      --output-dir)
        [[ $# -ge 2 ]] || die "--output-dir requires a value"
        OUTPUT_DIR="$2"
        shift 2
        ;;
      --output-dir=*)
        OUTPUT_DIR="${1#*=}"
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die "unknown argument: $1"
        ;;
    esac
  done
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"
}

xcodegen_bin() {
  if command -v xcodegen >/dev/null 2>&1; then
    command -v xcodegen
  elif [[ -x /opt/homebrew/bin/xcodegen ]]; then
    printf '/opt/homebrew/bin/xcodegen\n'
  else
    die "xcodegen not found. Install it or add it to PATH."
  fi
}

matching_identity_lines() {
  local requested_identity="$1"
  security find-identity -p codesigning -v 2>/dev/null | awk -v query="$requested_identity" '
    /^[[:space:]]*[0-9]+\)[[:space:]]+[A-Fa-f0-9]{40}[[:space:]]+"/ {
      if (index($0, query) > 0) {
        print
      }
    }
  '
}

identity_hash_from_line() {
  local identity_line="$1"
  if [[ "$identity_line" =~ ^[[:space:]]*[0-9]+\)[[:space:]]+([A-Fa-f0-9]{40})[[:space:]]+\".+\" ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

require_signing_identity() {
  log "Checking signing identity"
  local requested_identity="$SIGNING_IDENTITY"
  local identity_lines
  identity_lines="$(matching_identity_lines "$requested_identity")"
  if [[ -z "$identity_lines" ]]; then
    die "signing identity '$requested_identity' was not found. Run 'security find-identity -p codesigning -v' and pass --identity with an available identity."
  fi

  local identity_count
  identity_count="$(printf '%s\n' "$identity_lines" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
  if [[ "$identity_count" != "1" ]]; then
    printf '%s\n' "$identity_lines" >&2
    die "signing identity '$requested_identity' matched $identity_count identities. Pass the exact certificate hash with --identity."
  fi

  local identity_line
  identity_line="$identity_lines"
  if [[ "$LOCAL_MODE" -eq 0 && "$identity_line" != *"Developer ID Application"* ]]; then
    die "release mode requires a Developer ID Application identity. Use --local for Apple Development signing."
  fi

  local identity_hash
  identity_hash="$(identity_hash_from_line "$identity_line")" \
    || die "could not parse signing identity hash from: $identity_line"
  SIGNING_IDENTITY="$identity_hash"
}

release_preflight() {
  log "Running release preflight"
  [[ -n "$TEAM_ID" ]] || die "release mode requires TEAM_ID or --team-id."
  [[ -n "$NOTARY_PROFILE" ]] || die "release mode requires NOTARY_PROFILE or --notary-profile."
  require_signing_identity

  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    die "notarytool keychain profile '$NOTARY_PROFILE' could not be used. Create it with 'xcrun notarytool store-credentials'."
  fi
}

local_preflight() {
  log "Running local preflight"
  if [[ -n "$TEAM_ID" ]]; then
    log "Using team id $TEAM_ID"
  fi
}

generate_project() {
  log "Generating Xcode project"
  "$(xcodegen_bin)" generate
}

build_release_app() {
  log "Building Release app with manual signing flow"
  rm -rf "$DERIVED_DATA"
  local build_home="$ROOT_DIR/.build/release-home"
  local module_cache="$ROOT_DIR/.build/release-module-cache"
  local swiftpm_cache="$ROOT_DIR/.build/release-swiftpm-cache"
  mkdir -p "$build_home" "$module_cache" "$swiftpm_cache"

  local -a extra_build_settings=()
  if [[ "$SMOKE_MODE" -eq 1 ]]; then
    log "Building SMOKE_TEST entry point"
    extra_build_settings+=(SWIFT_ACTIVE_COMPILATION_CONDITIONS=SMOKE_TEST)
  fi

  HOME="$build_home" \
    CFFIXED_USER_HOME="$build_home" \
    XDG_CACHE_HOME="$build_home/.cache" \
    CLANG_MODULE_CACHE_PATH="$module_cache" \
    SWIFTPM_CACHE_PATH="$swiftpm_cache" \
    xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$swiftpm_cache/source-packages" \
    CODE_SIGNING_ALLOWED=NO \
    CLANG_MODULE_CACHE_PATH="$module_cache" \
    "${extra_build_settings[@]}" \
    build
}

built_app_path() {
  local product_app="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME"
  if [[ -d "$product_app" ]]; then
    printf '%s\n' "$product_app"
    return 0
  fi

  find "$DERIVED_DATA/Build/Products" -type d -name "$APP_NAME" -print -quit
}

stage_app() {
  log "Staging app"
  local built_app
  built_app="$(built_app_path)"
  [[ -n "$built_app" && -d "$built_app" ]] || die "$APP_NAME was not produced by xcodebuild."

  mkdir -p "$OUTPUT_DIR"
  APP_PATH="$OUTPUT_DIR/$APP_NAME"
  ZIP_PATH="$OUTPUT_DIR/Summond.zip"
  rm -rf "$APP_PATH" "$ZIP_PATH"
  ditto "$built_app" "$APP_PATH"
}

apply_launch_agent_spawn_constraint() {
  [[ -n "$TEAM_ID" ]] || return 0

  log "Applying LaunchAgent spawn constraint"
  local agent_plist="$APP_PATH/Contents/Library/LaunchAgents/net.garaba.summond.agent.plist"
  bash "$ROOT_DIR/scripts/apply-launch-agent-spawn-constraint.sh" "$agent_plist" "$TEAM_ID"
}

sign_path() {
  local path="$1"
  log "Signing ${path#"$ROOT_DIR"/}"
  local timestamp_flag=--timestamp
  if [[ "$SMOKE_MODE" -eq 1 ]]; then
    timestamp_flag=--timestamp=none
  fi
  codesign \
    --force \
    "$timestamp_flag" \
    --options runtime \
    --sign "$SIGNING_IDENTITY" \
    "$path"
}

sign_artifacts() {
  log "Signing nested code innermost first"
  if [[ "$SMOKE_MODE" -eq 1 ]]; then
    SIGNING_IDENTITY="-"
  else
    require_signing_identity
  fi

  local status_app="$APP_PATH/Contents/Library/LoginItems/SummondStatus.app"
  local agent_app="$APP_PATH/Contents/MacOS/SummondAgent.app"

  [[ -d "$status_app" ]] || die "nested status app not found at $status_app"
  [[ -d "$agent_app" ]] || die "nested agent app not found at $agent_app"

  sign_path "$status_app"
  sign_path "$agent_app"
  sign_path "$APP_PATH"
}

run_or_soft_fail() {
  local description="$1"
  shift

  "$@" && return 0
  local status=$?
  if [[ "$LOCAL_MODE" -eq 1 ]]; then
    warn "$description failed with status $status in local mode; continuing"
    return 0
  fi

  die "$description failed with status $status"
}

verify_artifacts() {
  log "Verifying signed app"
  run_or_soft_fail "codesign verification" \
    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
  run_or_soft_fail "spctl assessment" \
    spctl -a -vv --type exec "$APP_PATH"
}

verify_signed_identity() {
  local path="$1"
  local expected_identifier="$2"
  local description="$3"
  local details
  details="$(codesign -dvv "$path" 2>&1)"

  if ! grep -Fqx "Identifier=$expected_identifier" <<<"$details"; then
    printf '%s\n' "$details" >&2
    die "$description has unexpected signing identifier; expected $expected_identifier."
  fi

  if [[ -n "$TEAM_ID" ]] && ! grep -Fqx "TeamIdentifier=$TEAM_ID" <<<"$details"; then
    printf '%s\n' "$details" >&2
    die "$description has unexpected team identifier; expected $TEAM_ID."
  fi
}

verify_release_identity() {
  log "Verifying signing identities"
  verify_signed_identity "$APP_PATH" "net.garaba.summond" "main app"
  verify_signed_identity \
    "$APP_PATH/Contents/MacOS/SummondAgent.app" \
    "net.garaba.summond.agent" \
    "agent app"
  verify_signed_identity \
    "$APP_PATH/Contents/Library/LoginItems/SummondStatus.app" \
    "net.garaba.summond.ui" \
    "status item"
}

zip_app() {
  log "Creating notarization zip"
  rm -f "$ZIP_PATH"
  (
    cd "$OUTPUT_DIR"
    ditto -c -k --keepParent "$APP_NAME" "$(basename "$ZIP_PATH")"
  )
}

notarize_and_staple() {
  if [[ "$LOCAL_MODE" -eq 1 ]]; then
    log "Skipping notarization in local mode"
    return 0
  fi

  log "Submitting to notary service"
  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

  log "Stapling ticket"
  xcrun stapler staple "$APP_PATH"

  log "Validating stapled ticket"
  xcrun stapler validate "$APP_PATH"

  verify_artifacts

  log "Recreating zip with stapled app"
  zip_app
}

main() {
  parse_args "$@"

  require_tool xcodebuild
  require_tool xcrun
  require_tool codesign
  require_tool spctl
  require_tool ditto
  require_tool security

  if [[ "$LOCAL_MODE" -eq 1 ]]; then
    local_preflight
  else
    release_preflight
  fi

  generate_project
  build_release_app
  stage_app
  apply_launch_agent_spawn_constraint
  sign_artifacts
  verify_release_identity
  verify_artifacts
  zip_app
  notarize_and_staple

  log "Release artifacts ready"
  printf 'App: %s\nZip: %s\n' "$APP_PATH" "$ZIP_PATH"
}

main "$@"
