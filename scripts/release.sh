#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/release.sh [--local|--smoke] [options]

Build, sign, verify, package, and notarize Summond.app and Summond.dmg.

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
  --identity NAME          Signing identity. Default: SIGNING_IDENTITY env,
                           "Apple Development" in local mode, or
                           "Developer ID Application" in release mode.
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
  MARKETING_VERSION        Required in release mode (for example, 1.1).
  CURRENT_PROJECT_VERSION  Required in release mode; positive integer build number.
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
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
TEAM_ID="${TEAM_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist/release}"
RELEASE_MARKETING_VERSION="${MARKETING_VERSION:-}"
RELEASE_BUILD_NUMBER="${CURRENT_PROJECT_VERSION:-}"

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

  if [[ "$LOCAL_MODE" -eq 1 && -z "$TEAM_ID" ]]; then
    local identity_name certificate_subject
    identity_name="$(sed -n 's/^[^"]*"\([^"]*\)".*$/\1/p' <<<"$identity_line")"
    [[ -n "$identity_name" ]] || die "could not parse signing identity name from: $identity_line"
    certificate_subject="$(security find-certificate -c "$identity_name" -p \
      | openssl x509 -noout -subject -nameopt RFC2253)" \
      || die "could not read signing certificate '$identity_name'."
    if [[ "$certificate_subject" =~ (^|,)OU=([A-Z0-9]{10})(,|$) ]]; then
      TEAM_ID="${BASH_REMATCH[2]}"
    else
      die "could not determine the team id for signing certificate '$identity_name'."
    fi
  fi
}

validate_release_versions() {
  [[ "$RELEASE_MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] \
    || die "MARKETING_VERSION must contain one to three numeric components."
  [[ "$RELEASE_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] \
    || die "CURRENT_PROJECT_VERSION must be a positive integer."
}

release_preflight() {
  log "Running release preflight"
  [[ -n "$TEAM_ID" ]] || die "release mode requires TEAM_ID or --team-id."
  [[ -n "$NOTARY_PROFILE" ]] || die "release mode requires NOTARY_PROFILE or --notary-profile."
  [[ -n "$RELEASE_MARKETING_VERSION" ]] || die "release mode requires MARKETING_VERSION."
  [[ -n "$RELEASE_BUILD_NUMBER" ]] || die "release mode requires CURRENT_PROJECT_VERSION."
  validate_release_versions
  require_signing_identity

  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    die "notarytool keychain profile '$NOTARY_PROFILE' could not be used. Create it with 'xcrun notarytool store-credentials'."
  fi
}

local_preflight() {
  log "Running local preflight"
  if [[ -n "$RELEASE_MARKETING_VERSION" || -n "$RELEASE_BUILD_NUMBER" ]]; then
    [[ -n "$RELEASE_MARKETING_VERSION" && -n "$RELEASE_BUILD_NUMBER" ]] \
      || die "set both MARKETING_VERSION and CURRENT_PROJECT_VERSION."
    validate_release_versions
  fi
  if [[ "$SMOKE_MODE" -eq 1 ]]; then
    SIGNING_IDENTITY="-"
    log "Using ad-hoc signing for SMOKE_TEST"
  else
    require_signing_identity
  fi
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

  # Bash 3.2 + set -u rejects empty-array expansion; use positional params.
  set --
  if [[ "$SMOKE_MODE" -eq 1 ]]; then
    log "Building SMOKE_TEST entry point"
    set -- SWIFT_ACTIVE_COMPILATION_CONDITIONS=SMOKE_TEST
  fi
  if [[ -n "$RELEASE_MARKETING_VERSION" ]]; then
    set -- "$@" \
      "MARKETING_VERSION=$RELEASE_MARKETING_VERSION" \
      "CURRENT_PROJECT_VERSION=$RELEASE_BUILD_NUMBER"
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
    SUMMOND_APP_BUNDLE_IDENTIFIER=net.garaba.summond.build-host \
    "$@" \
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
  DMG_PATH="$OUTPUT_DIR/Summond.dmg"
  rm -rf "$APP_PATH" "$ZIP_PATH" "$DMG_PATH"
  ditto "$built_app" "$APP_PATH"
  plutil -replace CFBundleIdentifier -string net.garaba.summond "$APP_PATH/Contents/Info.plist"
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
  [[ -n "$SIGNING_IDENTITY" ]] || die "signing identity was not resolved during preflight."

  local status_app="$APP_PATH/Contents/Library/LoginItems/SummondStatus.app"
  local agent_app="$APP_PATH/Contents/MacOS/SummondAgent.app"

  [[ -d "$status_app" ]] || die "nested status app not found at $status_app"
  [[ -d "$agent_app" ]] || die "nested agent app not found at $agent_app"

  sign_path "$status_app"
  sign_path "$agent_app"
  sign_path "$APP_PATH"
}

verify_app_signature() {
  log "Verifying signed app"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
}

create_dmg() {
  [[ "$SMOKE_MODE" -eq 0 ]] || return 0

  log "Creating drag-install disk image"
  (
    local dmg_root
    dmg_root="$(mktemp -d "${TMPDIR:-/tmp}/summond-dmg.XXXXXX")"
    trap 'rm -rf -- "$dmg_root"' EXIT

    ditto "$APP_PATH" "$dmg_root/$APP_NAME"
    ln -s /Applications "$dmg_root/Applications"
    hdiutil create \
      -volname Summond \
      -srcfolder "$dmg_root" \
      -format UDZO \
      -ov \
      "$DMG_PATH"
  )
}

sign_dmg() {
  [[ -f "$DMG_PATH" ]] || return 0

  log "Signing disk image"
  codesign \
    --force \
    --timestamp \
    --sign "$SIGNING_IDENTITY" \
    "$DMG_PATH"
}

verify_dmg_signature() {
  [[ -f "$DMG_PATH" ]] || return 0

  log "Verifying signed disk image"
  codesign --verify --verbose=2 "$DMG_PATH"
  hdiutil verify "$DMG_PATH"
}

assess_gatekeeper() {
  log "Assessing release artifacts with Gatekeeper"
  local assessment_failed=0
  spctl -a -vv --type exec "$APP_PATH" || assessment_failed=1
  if [[ -f "$DMG_PATH" ]]; then
    spctl -a -vv --type open --context context:primary-signature "$DMG_PATH" \
      || assessment_failed=1
  fi

  if [[ "$assessment_failed" -eq 1 ]]; then
    if [[ "$LOCAL_MODE" -eq 1 ]]; then
      warn "Gatekeeper assessment failed in local mode; continuing"
    else
      die "Gatekeeper assessment failed"
    fi
  fi
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
  log "Creating distribution zip"
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

  log "Submitting disk image to notary service"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

  log "Stapling app ticket"
  xcrun stapler staple "$APP_PATH"

  log "Validating app ticket"
  xcrun stapler validate "$APP_PATH"

  log "Stapling disk image ticket"
  xcrun stapler staple "$DMG_PATH"

  log "Validating disk image ticket"
  xcrun stapler validate "$DMG_PATH"
}

main() {
  parse_args "$@"
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="Developer ID Application"
    [[ "$LOCAL_MODE" -eq 0 ]] || SIGNING_IDENTITY="Apple Development"
  fi

  require_tool xcodebuild
  require_tool xcrun
  require_tool codesign
  require_tool spctl
  require_tool ditto
  require_tool hdiutil
  require_tool plutil
  require_tool security
  require_tool openssl

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
  verify_app_signature
  create_dmg
  sign_dmg
  verify_dmg_signature
  notarize_and_staple
  zip_app
  verify_release_identity
  verify_app_signature
  verify_dmg_signature
  assess_gatekeeper

  log "Release artifacts ready"
  printf 'App: %s\nZip: %s\n' "$APP_PATH" "$ZIP_PATH"
  if [[ -f "$DMG_PATH" ]]; then
    printf 'DMG: %s\n' "$DMG_PATH"
  fi
}

main "$@"
