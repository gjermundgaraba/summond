#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/release.sh [--local|--smoke] [options]

Build, sign, verify, package, and optionally notarize Summond artifacts.

Modes:
  default release mode
      Requires a Developer ID Application identity, TEAM_ID, and a notarytool
      keychain profile. Verification and notarization failures are fatal.

  --local
      Builds the isolated Summond Local flavor, signs with the requested
      identity, skips notarization, and reports Gatekeeper assessment failures
      without aborting. Signing identity mismatches remain fatal.

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
                           dist/local in local mode, dist/release otherwise.
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
PROJECT_PATH="$ROOT_DIR/Summond.xcodeproj"
SCHEME="Summond"
CONFIGURATION="Release"

LOCAL_MODE=0
SMOKE_MODE=0
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
TEAM_ID="${TEAM_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
OUTPUT_DIR="${OUTPUT_DIR:-}"
RELEASE_MARKETING_VERSION="${MARKETING_VERSION:-}"
RELEASE_BUILD_NUMBER="${CURRENT_PROJECT_VERSION:-}"

DERIVED_DATA=""
APP_PRODUCT_NAME=""
AGENT_PRODUCT_NAME=""
STATUS_PRODUCT_NAME=""
STATUS_DISPLAY_NAME=""
APP_BUNDLE_IDENTIFIER=""
AGENT_BUNDLE_IDENTIFIER=""
STATUS_BUNDLE_IDENTIFIER=""
AGENT_MACH_SERVICE=""
AGENT_PLIST_NAME=""
URL_SCHEME=""
APP_NAME=""
AGENT_APP_NAME=""
STATUS_APP_NAME=""

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

configure_artifact() {
  if [[ "$LOCAL_MODE" -eq 1 && "$SMOKE_MODE" -eq 0 ]]; then
    DERIVED_DATA="$ROOT_DIR/.build/local-release-dd"
    APP_PRODUCT_NAME="Summond Local"
    AGENT_PRODUCT_NAME="SummondLocalAgent"
    STATUS_PRODUCT_NAME="SummondLocalStatus"
    APP_BUNDLE_IDENTIFIER="net.garaba.summond.local"
    URL_SCHEME="summond-local"
    [[ -n "$OUTPUT_DIR" ]] || OUTPUT_DIR="$ROOT_DIR/dist/local"
  else
    DERIVED_DATA="$ROOT_DIR/.build/release-dd"
    APP_PRODUCT_NAME="Summond"
    AGENT_PRODUCT_NAME="SummondAgent"
    STATUS_PRODUCT_NAME="SummondStatus"
    APP_BUNDLE_IDENTIFIER="net.garaba.summond"
    URL_SCHEME="summond"
    [[ -n "$OUTPUT_DIR" ]] || OUTPUT_DIR="$ROOT_DIR/dist/release"
  fi

  AGENT_BUNDLE_IDENTIFIER="$APP_BUNDLE_IDENTIFIER.agent"
  STATUS_BUNDLE_IDENTIFIER="$APP_BUNDLE_IDENTIFIER.ui"
  STATUS_DISPLAY_NAME="$APP_PRODUCT_NAME Menu Bar"
  AGENT_MACH_SERVICE="$AGENT_BUNDLE_IDENTIFIER.xpc"
  AGENT_PLIST_NAME="$AGENT_BUNDLE_IDENTIFIER.plist"
  APP_NAME="$APP_PRODUCT_NAME.app"
  AGENT_APP_NAME="$AGENT_PRODUCT_NAME.app"
  STATUS_APP_NAME="$STATUS_PRODUCT_NAME.app"
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

certificate_pem_for_hash() {
  local expected_hash="$1"
  awk -v expected_hash="$expected_hash" '
    $0 == "SHA-1 hash: " expected_hash { matched = 1; next }
    !complete && matched && $0 == "-----BEGIN CERTIFICATE-----" { capture = 1 }
    capture { print }
    capture && $0 == "-----END CERTIFICATE-----" { capture = 0; complete = 1 }
    END { if (!complete) exit 1 }
  '
}

team_id_from_subject() {
  awk '
    /^[[:space:]]*OU=/ {
      sub(/^[[:space:]]*OU=/, "")
      if ($0 ~ /^[A-Z0-9]+$/ && length($0) == 10) {
        print
        found = 1
        exit
      }
    }
    END { if (!found) exit 1 }
  '
}

team_id_for_identity() {
  local identity_hash="$1"
  local certificate_pem certificate_subject
  [[ -x /usr/bin/openssl ]] || die "required tool not found: /usr/bin/openssl"
  certificate_pem="$(security find-certificate -a -Z -p 2>/dev/null \
    | certificate_pem_for_hash "$identity_hash")" \
    || die "could not find signing certificate '$identity_hash'."
  certificate_subject="$(printf '%s\n' "$certificate_pem" \
    | /usr/bin/openssl x509 -noout -subject -nameopt sep_multiline 2>/dev/null)" \
    || die "could not read signing certificate '$identity_hash'."
  printf '%s\n' "$certificate_subject" | team_id_from_subject \
    || die "could not determine the team id for signing certificate '$identity_hash'."
}

require_signing_identity() {
  log "Checking signing identity"
  local requested_identity="$SIGNING_IDENTITY"
  local identity_lines
  identity_lines="$(matching_identity_lines "$requested_identity")"
  if [[ -z "$identity_lines" ]]; then
    if [[ "$LOCAL_MODE" -eq 1 ]]; then
      die "signing identity '$requested_identity' was not found. Create an Apple Development certificate in Xcode, or set SIGNING_IDENTITY to one listed by 'security find-identity -p codesigning -v'."
    fi
    die "signing identity '$requested_identity' was not found. Run 'security find-identity -p codesigning -v' and set SIGNING_IDENTITY or pass --identity with an available identity."
  fi

  local identity_count
  identity_count="$(printf '%s\n' "$identity_lines" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')"
  if [[ "$identity_count" != "1" ]]; then
    printf '%s\n' "$identity_lines" >&2
    die "signing identity '$requested_identity' matched $identity_count identities. Set SIGNING_IDENTITY or pass --identity with an exact certificate hash."
  fi

  local identity_line
  identity_line="$identity_lines"
  if [[ "$LOCAL_MODE" -eq 0 && "$identity_line" != *"Developer ID Application"* ]]; then
    die "release mode requires a Developer ID Application identity. Use --local for Apple Development signing."
  fi

  local identity_hash identity_name
  identity_hash="$(identity_hash_from_line "$identity_line")" \
    || die "could not parse signing identity hash from: $identity_line"
  identity_name="${identity_line#*\"}"
  identity_name="${identity_name%\"}"
  [[ -n "$identity_name" && "$identity_name" != "$identity_line" ]] \
    || die "could not parse signing identity name from: $identity_line"
  log "Using signing identity $identity_name ($identity_hash)"
  SIGNING_IDENTITY="$identity_hash"

  if [[ "$LOCAL_MODE" -eq 1 && -z "$TEAM_ID" ]]; then
    TEAM_ID="$(team_id_for_identity "$identity_hash")"
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
      "SUMMOND_APP_PRODUCT_NAME=$APP_PRODUCT_NAME" \
      "SUMMOND_AGENT_PRODUCT_NAME=$AGENT_PRODUCT_NAME" \
      "SUMMOND_STATUS_PRODUCT_NAME=$STATUS_PRODUCT_NAME" \
      "SUMMOND_STATUS_DISPLAY_NAME=$STATUS_DISPLAY_NAME" \
      "SUMMOND_APP_BUNDLE_IDENTIFIER=$APP_BUNDLE_IDENTIFIER" \
      "SUMMOND_BUILD_HOST_BUNDLE_IDENTIFIER=$APP_BUNDLE_IDENTIFIER.build-host" \
      "SUMMOND_URL_SCHEME=$URL_SCHEME" \
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
  ZIP_PATH="$OUTPUT_DIR/$APP_PRODUCT_NAME.zip"
  DMG_PATH="$OUTPUT_DIR/$APP_PRODUCT_NAME.dmg"
  rm -rf "$APP_PATH" "$ZIP_PATH" "$DMG_PATH"
  ditto "$built_app" "$APP_PATH"
  plutil -replace CFBundleIdentifier -string "$APP_BUNDLE_IDENTIFIER" \
    "$APP_PATH/Contents/Info.plist"
}

apply_launch_agent_spawn_constraint() {
  [[ -n "$TEAM_ID" ]] || return 0

  log "Applying LaunchAgent spawn constraint"
  local agent_plist="$APP_PATH/Contents/Library/LaunchAgents/$AGENT_PLIST_NAME"
  bash "$ROOT_DIR/scripts/apply-launch-agent-spawn-constraint.sh" \
    "$agent_plist" "$TEAM_ID" "$AGENT_BUNDLE_IDENTIFIER"
}

verify_launch_agent_plist() {
  log "Verifying LaunchAgent wiring"
  local agent_plist="$APP_PATH/Contents/Library/LaunchAgents/$AGENT_PLIST_NAME"
  local expected_program="Contents/MacOS/$AGENT_APP_NAME/Contents/MacOS/$AGENT_PRODUCT_NAME"

  [[ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$agent_plist")" \
    == "$AGENT_BUNDLE_IDENTIFIER" ]] \
    || die "LaunchAgent label does not match $AGENT_BUNDLE_IDENTIFIER."
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$agent_plist")" \
    == "$expected_program" ]] \
    || die "LaunchAgent program does not match $expected_program."
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :AssociatedBundleIdentifiers' "$agent_plist")" \
    == "$APP_BUNDLE_IDENTIFIER" ]] \
    || die "LaunchAgent association does not match $APP_BUNDLE_IDENTIFIER."
  [[ "$(/usr/libexec/PlistBuddy -c "Print :MachServices:$AGENT_MACH_SERVICE" "$agent_plist")" \
    == "true" ]] \
    || die "LaunchAgent Mach service does not match $AGENT_MACH_SERVICE."
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

  local status_app="$APP_PATH/Contents/Library/LoginItems/$STATUS_APP_NAME"
  local agent_app="$APP_PATH/Contents/MacOS/$AGENT_APP_NAME"

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
      -volname "$APP_PRODUCT_NAME" \
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
  local declared_agent_path declared_url_scheme declared_status_name status_info
  declared_agent_path="$(
    plutil -extract SummondAgentBundlePath raw -o - "$APP_PATH/Contents/Info.plist"
  )"
  [[ "$declared_agent_path" == "Contents/MacOS/$AGENT_APP_NAME" ]] \
    || die "main app declares an unexpected agent bundle path: $declared_agent_path"
  declared_url_scheme="$(
    plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes.0 raw -o - \
      "$APP_PATH/Contents/Info.plist"
  )"
  [[ "$declared_url_scheme" == "$URL_SCHEME" ]] \
    || die "main app declares an unexpected URL scheme: $declared_url_scheme"
  status_info="$APP_PATH/Contents/Library/LoginItems/$STATUS_APP_NAME/Contents/Info.plist"
  declared_status_name="$(plutil -extract CFBundleDisplayName raw -o - "$status_info")"
  [[ "$declared_status_name" == "$STATUS_DISPLAY_NAME" ]] \
    || die "status item declares an unexpected display name: $declared_status_name"
  verify_signed_identity "$APP_PATH" "$APP_BUNDLE_IDENTIFIER" "main app"
  verify_signed_identity \
    "$APP_PATH/Contents/MacOS/$AGENT_APP_NAME" \
    "$AGENT_BUNDLE_IDENTIFIER" \
    "agent app"
  verify_signed_identity \
    "$APP_PATH/Contents/Library/LoginItems/$STATUS_APP_NAME" \
    "$STATUS_BUNDLE_IDENTIFIER" \
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
  configure_artifact
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

  if [[ "$LOCAL_MODE" -eq 1 ]]; then
    local_preflight
  else
    release_preflight
  fi

  generate_project
  build_release_app
  stage_app
  apply_launch_agent_spawn_constraint
  verify_launch_agent_plist
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
