.PHONY: help project build dev-build core-build test core-test app-test ui-test test-tart smoke-tart tart-ensure-base lint lint-fix icon release-local release-build release

XCODEBUILD ?= xcodebuild
XCODEGEN ?= $(or $(shell command -v xcodegen 2>/dev/null),/opt/homebrew/bin/xcodegen)
BASE_VM ?= summond-macos-tahoe-xcodegen-base
PROJECT := Summond.xcodeproj
SCHEME := Summond
DESTINATION ?= platform=macOS

help:
	@printf '%s\n' \
		'Targets:' \
		'  make project        Generate Summond.xcodeproj with XcodeGen' \
		'  make build          Build the Debug macOS app (alias: dev-build)' \
		'  make dev-build      Build the Debug macOS app' \
		'  make core-build     Build the Core Swift package' \
		'  make test           Run Core package tests and app unit tests' \
		'  make core-test      Run Core package tests' \
		'  make app-test       Run Xcode app unit tests' \
		'  make ui-test        Run XCUITest UI tests (drives a real GUI; intended for the Tart VM)' \
		'  make test-tart      Run unit + UI tests in a clean disposable Tart VM' \
		'  make smoke-tart     Unattended launchctl + XPC smoke in a Tart VM' \
		'  make tart-ensure-base  Create the reusable Tart base VM if missing' \
		'  make lint           Run swift-format lint' \
		'  make lint-fix       Apply swift-format formatting' \
		'  make icon           Regenerate Resources/AppIcon.icns from the vector generator' \
		'  make release-local  Create local signed Release app/zip without notarization' \
		'  make release-build  Alias for release-local' \
		'  make release        Create Developer ID signed and notarized app/zip'

project:
	$(XCODEGEN) generate

build: dev-build

dev-build: project
	$(XCODEBUILD) -project $(PROJECT) -scheme $(SCHEME) -configuration Debug build

core-build:
	swift build --package-path Core

test: core-test app-test

core-test:
	swift test --package-path Core

app-test: project
	$(XCODEBUILD) test -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)'

# XCUITest UI tests drive a real GUI app, so they run only inside the Tart VM
# (via test-tart). Kept in a separate scheme so host `make test`/`app-test`
# stays unit-only and never hijacks a developer's screen. The guard refuses to
# run on a host Mac unless explicitly forced; test-tart sets it inside the VM.
ui-test: project
	@[ "$${ALLOW_HOST_UITESTS:-}" = "1" ] || { echo 'make ui-test drives a real GUI; run via make test-tart, or set ALLOW_HOST_UITESTS=1 to force on this host.' >&2; exit 1; }
	$(XCODEBUILD) test -project $(PROJECT) -scheme SummondUITests -destination '$(DESTINATION)' -test-timeouts-enabled YES -maximum-test-execution-time-allowance 180

test-tart:
	scripts/tart-test.sh "$(BASE_VM)"

smoke-tart:
	scripts/tart-test.sh "$(BASE_VM)" smoke

tart-ensure-base:
	scripts/tart-ensure-base.sh "$(BASE_VM)"

lint:
	xcrun swift format lint --strict --recursive Core/Sources Core/Tests App AppTests Agent Status UITests

lint-fix:
	xcrun swift format format --in-place --recursive Core/Sources Core/Tests App AppTests Agent Status UITests

# Regenerate the app icon from the vector generator. Deterministic: it renders
# every iconset size offscreen and runs iconutil, writing Resources/AppIcon.icns.
icon:
	swift $(CURDIR)/Resources/generate-appicon.swift $(CURDIR)/Resources/AppIcon.icns

release-local:
	scripts/release.sh --local

release-build: release-local

release:
	scripts/release.sh
