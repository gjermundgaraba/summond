#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Summond"
BUNDLE_ID="net.garaba.summond"
SCHEME="Summond"
CONFIGURATION="Debug"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Summond.xcodeproj"
DERIVED_DATA_DIR="$ROOT_DIR/.build/xcode-derived-data"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
MODE="${1:-run}"

usage() {
  echo "usage: ${0##*/} [run|debug|logs|telemetry|verify|help]" >&2
}

if [[ $# -gt 1 ]]; then
  usage
  exit 2
fi

case "$MODE" in
  run | debug | logs | telemetry | verify)
    ;;
  help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac

stop_running_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

build_app() {
  make -C "$ROOT_DIR" project
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    build

  if [[ ! -x "$APP_BINARY" ]]; then
    echo "error: build did not produce $APP_BINARY" >&2
    exit 1
  fi
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

stop_running_app
build_app

case "$MODE" in
  run)
    open_app
    ;;
  debug)
    exec lldb -- "$APP_BINARY"
    ;;
  logs)
    open_app
    exec /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  telemetry)
    open_app
    exec /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  verify)
    open_app
    app_pid=""
    for _ in {1..20}; do
      if app_pid="$(pgrep -x "$APP_NAME" | head -n 1)"; then
        break
      fi
      sleep 0.25
    done
    if [[ -n "$app_pid" ]]; then
      sleep 1
      if kill -0 "$app_pid" 2>/dev/null; then
        echo "$APP_NAME launched successfully from $APP_BUNDLE"
        exit 0
      fi
    fi
    echo "error: $APP_NAME did not remain running after launch" >&2
    exit 1
    ;;
esac
