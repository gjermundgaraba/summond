# Architecture

Summond is a macOS preferences app, LaunchAgent, status item, and shared core
library that summons app windows from global shortcuts: it opens, focuses, or
moves them onto the current Space.

## Component Diagram

```
┌──────────────────────────┐        summond:// URLs
│ SummondStatus.app       │ ─────────────────────────┐
│ menu bar login item      │                          │
└────────────┬─────────────┘                          │
             │ XPC status/reload                      │
             ▼                                        ▼
┌──────────────────────────┐   SMAppService   ┌──────────────────────────┐
│ SummondAgent            │ ◀──────────────▶ │ Summond.app             │
│ LaunchAgent + listener   │                  │ preferences + service UI │
└────────────┬─────────────┘                  └────────────┬─────────────┘
             │                                             │
             └──────────────┬──────────────────────────────┘
                            ▼
                ┌──────────────────────────┐
                │ SummondCore             │
                │ config, compiler, XPC,   │
                │ engine, app opening      │
                └────────────┬─────────────┘
                             ▼
                Application Support file
                Summond/configuration.json
```

## Components

### `Summond.app`

SwiftUI preferences app with bundle identifier `net.garaba.summond`.

- Edits stored bindings and verbose logging.
- Registers/unregisters the LaunchAgent with
  `SMAppService.agent(plistName: "net.garaba.summond.agent.plist")`.
- Registers/unregisters the menu bar login item with
  `SMAppService.loginItem(identifier: "net.garaba.summond.ui")`.
- Handles `summond://` URLs from the status item.
- Talks to the agent over Mach XPC service
  `net.garaba.summond.agent.xpc`.

### `SummondAgent`

LaunchAgent embedded as a faceless helper app bundle at
`Contents/MacOS/SummondAgent.app` (bundle identifier
`net.garaba.summond.agent`, `LSUIElement`). It is a bundle rather than a bare
executable so that the Accessibility permission it requests displays as
"Summond" with the app icon. TCC shows the requesting bundle's display name
and icon; a bare tool would show the raw executable name and a generic
icon. It lives under `Contents/MacOS` (a standard code location) rather than
`Contents/Resources` so the outer app signs it as nested code with its own
cdhash instead of sealing it as a flat resource tree. The LaunchAgent plist's
`BundleProgram` points at
`Contents/MacOS/SummondAgent.app/Contents/MacOS/SummondAgent`.

- Runs in the user's Aqua session.
- Loads configuration from the shared Application Support file.
- Registers configured shortcuts as system hot keys (`RegisterEventHotKey`),
  which needs no permission and keeps working while another process holds
  secure keyboard entry. Summond still treats Accessibility as an unconditional
  setup requirement because its window-management behaviors depend on it.
- Exports XPC status, reload, and Accessibility-prompt requests.
- Uses `KeepAlive` crash-only semantics: launchd restarts it after an
  unsuccessful exit, but it is not a polling supervisor.

### `SummondStatus.app`

Menu bar login item embedded at
`Contents/Library/LoginItems/SummondStatus.app` with bundle identifier
`net.garaba.summond.ui`.

- Shows agent reachability, Accessibility, shortcut listener,
  and configuration state.
- Sends status and reload requests through the same agent XPC service.
- Opens the preferences app with `summond://` URLs for user actions.

### `SummondCore`

SwiftPM library shared by all targets. It contains the configuration model,
JSON file store, binding compiler, XPC protocol/codecs, status mapping,
event engine, app-opening runtime, Dock menu integration, and Space-moving
runtime.

## Configuration Data Flow

```
Preferences draft
  → validate shortcut, duplicate shortcut, and non-empty bundle ID
  → atomically save JSON to ~/Library/Application Support/Summond/configuration.json
  → XPC reloadConfiguration()
  → agent lenient compile
      resolved apps become active bindings
      missing bundle IDs become unresolvedBundleIDs
      hard invalid config preserves previous snapshot
  → HotKeyEngine re-registers the snapshot's hot keys
```

The UI validates before save. The agent validates again because the shared file
can be edited or replaced independently. Application resolution is separate:
installed apps can change after the UI saves.

Unresolved bundle identifiers are degraded state, not corruption. The agent
skips those bindings, reports them in `AgentStatus.unresolvedBundleIDs`, and
keeps all resolvable bindings active.

## Shortcut Dispatch

```
window server matches a registered hot key
  → Carbon kEventHotKeyPressed on the main run loop
  → HotKeyEngine looks up the binding by hot-key ID
  → log match
  → Task { await AppOpener.open(binding) }
```

Each active binding is registered with `RegisterEventHotKey`; matching happens
inside the window server, which consumes the combo system-wide and delivers
only registered shortcuts to the agent — other keystrokes never reach the
process. If launching, opening a new window, moving windows, or activation
later fails, the shortcut is still consumed and the failure is logged.
Registrations rejected by macOS (for example, a combo held exclusively by
another app) are reported per binding in `AgentStatus.failedShortcuts` while
the remaining bindings stay active.

## App Opening

`launch` performs a normal app launch or activation through `NSWorkspace`.

**New Window** (Swift `.newWindow`, stored `new_window`) checks whether the app
already has a window on the current Space using runtime-resolved private SkyLight
queries. If the app is running but has no window on the current Space (including
an app with no windows at all), the runtime asks the Dock accessibility menu for
**New Window**, waits for a new current-Space window, and activates the app.
Failures are logged and are non-fatal.

`move` checks for current-Space windows first. If windows exist on another
Space, it moves them to the current Space and activates the app. Moving relies
on private SkyLight functions resolved at runtime. On supported macOS 26+
systems, Summond uses the bridged window-management operation that does not
require disabling SIP.

## Concurrency Model

- `AgentSupervisor` and `HotKeyEngine` are `@MainActor`. Carbon delivers
  hot-key events on the main run loop, so dispatch enters the engine with a
  main-actor assertion, not a hop. Verbose-logging state is shared atomically
  with the runtime collaborators that emit diagnostics.
- XPC calls enter on Foundation-managed queues and hop to `@MainActor` for the
  supervisor.
- `AppOpener` is an actor that deduplicates in-flight opens per bundle ID.
- Storage wrappers that can be called from multiple contexts use `NSLock`.
- Slow app-opening work is async; hot-key dispatch itself stays synchronous.

## Failure Semantics

- Missing Accessibility prevents ready health. Higher-priority configuration or
  listener failures may be surfaced first; hot-key delivery itself uses Carbon
  and may continue while the required window-management access is missing.
- Hot-key handler installation failure and per-binding registration failures
  are logged and surfaced through status; failed bindings do not disable the
  rest.
- Undecodable JSON is reported as corrupt, structurally invalid configuration as
  invalid, and file-access failures as unavailable. All three preserve the
  previous active snapshot.
- Launch-history persistence failure is logged; the current launch still uses
  its in-memory restart history and remains operational.
- Fresh storage is not an error; the default configuration is empty.
- Missing target apps produce `unresolvedBundleIDs`; resolvable bindings remain
  active.
- Dock menu, window creation, window move, and activation failures are logged
  app-open failures, not process crashes.
- The LaunchAgent plist uses `KeepAlive` with `SuccessfulExit = false`, so
  launchd restarts crash exits but does not restart intentional successful
  exits. A crash-looping agent cannot wedge the keyboard: the OS releases a
  dead process's hot keys, unlike an abandoned active event tap.

## Storage Format

Configuration is JSON encoded `SummondConfiguration` stored at
`~/Library/Application Support/Summond/configuration.json`.

Top-level fields:

- `bindings`
- `verboseLogging`

Each binding stores a stable UUID, a shortcut (`key`, `mods`), and a target
(`bundleID`, `mode`). A missing file is a fresh empty configuration. Ordinary
saves refuse to overwrite unreadable, invalid, or unavailable configuration.
Explicit recovery replaces unreadable saved data with the configuration the app
currently shows.

## XPC Boundary

The agent listens on Mach service `net.garaba.summond.agent.xpc`. The exported
protocol supports:

- `status`
- `reloadConfiguration`
- `requestAccessibilityPrompt`

For signed builds, both sides install
`NSXPCConnection.setCodeSigningRequirement(_:)` requirements. The listener pins
incoming clients to the agent's own team identifier and exact allowed client
bundle identifiers: `net.garaba.summond` and `net.garaba.summond.ui`. The app
and status item pin the remote service to the same team identifier and exact
`net.garaba.summond.agent` bundle identifier. The team identifier is read at
runtime with `SecCodeCopySelf`/`SecCodeCopySigningInformation`, so Apple
Development and Developer ID builds work for whichever team signed the bundle.
When no team identifier can be derived, clients skip the remote requirement.
Debug and `SMOKE_TEST` agents may also skip the incoming-client requirement;
non-debug/non-smoke agents reject the connection without a team ID.

## Packaging Layout

XcodeGen creates three app targets plus unit and UI test targets. The built main
app has this bundle layout:

```text
Summond.app/
  Contents/
    MacOS/
      Summond
      SummondAgent.app
    Library/
      LaunchAgents/net.garaba.summond.agent.plist
      LoginItems/SummondStatus.app
```

A post-build script embeds `SummondAgent.app`, the LaunchAgent plist, and
`SummondStatus.app` into that bundle.

The LaunchAgent plist declares:

- `Label`: `net.garaba.summond.agent`
- `BundleProgram`: `Contents/MacOS/SummondAgent.app/Contents/MacOS/SummondAgent`
- `MachServices`: `net.garaba.summond.agent.xpc`
- `LimitLoadToSessionType`: `Aqua`
- `RunAtLoad`: `true`
- `KeepAlive.SuccessfulExit`: `false`
- `AssociatedBundleIdentifiers`: `net.garaba.summond`

When a development team or release team ID is available, the build and release
flows also add a generated `SpawnConstraint` with:

- `team-identifier`: the signing team ID
- `signing-identifier`: `net.garaba.summond.agent`

### Local Development Flavor

`make install-local` installs `/Applications/Summond Local.app` without
replacing the published app. The local flavor uses the
`net.garaba.summond.local` identifier family, `summond-local://` URLs,
`net.garaba.summond.local.agent.xpc`, and
`~/Library/Application Support/Summond Local/`. Its LaunchAgent, login item,
preferences, logs, and Accessibility permission are therefore independent of
production. `make uninstall-local` unregisters and removes only this flavor.

The app records the last registered `CFBundleVersion` independently for each
service. On the first launch of a new build, it re-registers each enabled service
so ServiceManagement uses the updated executable; enabled services also repair
themselves when they stop responding or running. Local rebuilds commonly keep
the same build number, so `make install-local` refreshes them explicitly.

## Signing and Notarization

Distribution is Developer ID outside the Mac App Store. Hardened runtime is
enabled, the app sandbox is disabled, and no target currently needs custom
entitlements.

`scripts/release.sh` uses a Release build plus manual re-sign flow because the
bundle contains a nested login item and a nested `SummondAgent` app bundle.
Signing order is innermost first:

1. `Contents/Library/LoginItems/SummondStatus.app`
2. `Contents/MacOS/SummondAgent.app`
3. `Summond.app`

Every signing command uses `--options runtime --force`. Release and local
signing use `--timestamp`; smoke uses `--timestamp=none`. Release mode runs the
lint and unit-test gates, then requires a Developer ID Application identity, a
team ID, marketing and build versions, and a notarytool keychain profile. It
creates and Developer ID signs a DMG containing the app and an `/Applications`
shortcut, then submits that image with `notarytool --wait`. The accepted tickets
are stapled to both the app and DMG; a zip is then created from the stapled app.
Local mode builds the isolated `Summond Local` flavor, signs with the provided
identity, and skips notarization. Signature verification is always fatal; only
the local Gatekeeper assessment may warn and continue.

## Testability

The core package keeps most behavior behind testable boundaries:

- `ConfigurationStore`
- `AppResolver`
- `AppRuntime`
- `MacOSAppRuntimeSystem`
- `AgentClientProtocol`
- pure codecs, validators, requirement builders, and status mappers

Run core tests with:

```bash
make core-test
```

Run the host unit suite (Core + app) with:

```bash
make test
```

The agent's cross-process surface is covered in two layers:

- **Routine (`make test`)**: an anonymous-`NSXPCListener` integration test
  drives the real `AgentClient` (NSXPC interface, async reply bridge, and
  `AgentStatus` codec across a genuine XPC boundary), and a static test
  asserts the LaunchAgent plist's `MachServices` name, `BundleProgram` path, and
  bundle identifiers against the single `SummondBundleIdentifiers` constants. No
  signing, launchd, or VM.
- **Unattended VM (`make smoke-tart`)**: a clean Tart VM builds an ad-hoc-signed
  `SMOKE_TEST` app, `launchctl`-loads the embedded agent (the `SMOKE_TEST` build
  relaxes the team requirement so an ad-hoc client connects), and round-trips XPC
  status against the real agent over the mach service. This covers launchd spawn,
  mach-name resolution, the real `AgentXPCService`, and the codec. It cannot
  cover `SMAppService` registration, Login Items approval, the team-signed
  requirement, or `SpawnConstraint`, which need a signed/pre-approved Mac and
  stay manual.

The Tart UI harness (`UITests/SummondUITests.swift`) exercises real SwiftUI
views, the app model, and configuration persistence in AppKit-hosted windows.
Production `WindowGroup`/`Settings` presentation, menu shortcuts, the
`summond://` deep link / `onOpenURL`, window placement/restoration, and
`scenePhase` reactivation stay manual.
