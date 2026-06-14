.PHONY: help project build dev-build core-build test core-test app-test test-tart tart-ensure-base lint lint-fix release-local release-build release

XCODEBUILD ?= xcodebuild
XCODEGEN ?= $(or $(shell command -v xcodegen 2>/dev/null),/opt/homebrew/bin/xcodegen)
BASE_VM ?= codex-macos-tahoe-xcodegen-base
PROJECT := Keybindd.xcodeproj
SCHEME := Keybindd
DESTINATION ?= platform=macOS

help:
	@printf '%s\n' \
		'Targets:' \
		'  make project        Generate Keybindd.xcodeproj with XcodeGen' \
		'  make build          Build the Debug macOS app (alias: dev-build)' \
		'  make dev-build      Build the Debug macOS app' \
		'  make core-build     Build the Core Swift package' \
		'  make test           Run Core package tests and app unit tests' \
		'  make core-test      Run Core package tests' \
		'  make app-test       Run Xcode app unit tests' \
		'  make test-tart      Run tests in a clean disposable Tart VM' \
		'  make tart-ensure-base  Create the reusable Tart base VM if missing' \
		'  make lint           Run swift-format lint' \
		'  make lint-fix       Apply swift-format formatting' \
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

test-tart:
	scripts/tart-test.sh "$(BASE_VM)"

tart-ensure-base:
	scripts/tart-ensure-base.sh "$(BASE_VM)"

lint:
	xcrun swift format lint --recursive Core/Sources Core/Tests App AppTests Agent Status

lint-fix:
	xcrun swift format format --in-place --recursive Core/Sources Core/Tests App AppTests Agent Status

release-local:
	scripts/release.sh --local

release-build: release-local

release:
	scripts/release.sh
