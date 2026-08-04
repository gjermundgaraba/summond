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
- Installs a global `CGEvent` tap after Accessibility and Input Monitoring
  permissions are granted.
- Exports XPC status, reload, Accessibility-prompt, and Input Monitoring-prompt
  requests.
- Uses `KeepAlive` crash-only semantics: launchd restarts it after an
  unsuccessful exit, but it is not a polling supervisor.

### `SummondStatus.app`

Menu bar login item embedded at
`Contents/Library/LoginItems/SummondStatus.app` with bundle identifier
`net.garaba.summond.ui`.

- Shows agent reachability, Accessibility, Input Monitoring, shortcut listener,
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
  → lock-protected snapshot replacement in KeyEventEngine
```

The UI validates before save. The agent validates again because the shared file
can be edited or replaced independently. Application resolution is separate:
installed apps can change after the UI saves.

Unresolved bundle identifiers are degraded state, not corruption. The agent
skips those bindings, reports them in `AgentStatus.unresolvedBundleIDs`, and
keeps all resolvable bindings active.

## Key Event Hot Path

```
CGEvent tap keyDown
  → KeyEventEngine.handleKeyEvent()
  → extract CGKeyCode + relevant CGEventFlags
  → O(1) lookup in BindingSnapshot
  → if no match: return event
  → if match:
      log match
      Task { await AppOpener.open(binding) }
      return nil to consume the event
```

Matched shortcuts are consumed immediately. If launching, opening a new window,
moving windows, or activation later fails, the original key event is still
swallowed and the failure is logged.

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

- `AgentSupervisor` is `@MainActor`.
- `KeyEventEngine` is `@unchecked Sendable`. The event tap runs on a dedicated
  `net.garaba.summond.keytap` thread with its own run loop. Engine state lives
  behind an `OSAllocatedUnfairLock`; the tap callback holds the lock only long
  enough to copy out the snapshot. Verbose-logging state is shared atomically
  with the runtime collaborators that emit diagnostics.
- Engine methods are thread-safe. XPC calls enter on Foundation-managed queues
  and hop to `@MainActor` for the supervisor. Status replies await any in-flight
  event-tap startup attempt without blocking the main actor.
- `AppOpener` is an actor that deduplicates in-flight opens per bundle ID.
- Storage wrappers that can be called from multiple contexts use `NSLock`.
- Slow app-opening work is async; the key-event hot path stays synchronous.

## Failure Semantics

- Missing Accessibility or Input Monitoring permission prevents event tap
  installation. The agent stays alive, polls trust state, and starts the engine
  when both permissions are present.
- Event tap creation failure is logged and surfaced through status.
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
  exits.
- A restart-loop breaker watches recent agent launches. When the throttle trips,
  the agent defers tap installation, surfaces `.restartLoopDetected`, keeps
  polling, and recovers once the throttle window clears.

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
- `requestInputMonitoringPrompt`

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
zips with `ditto --keepParent`, submits with `notarytool --wait`, staples,
validates, and reruns verification. Local mode signs with the provided identity
and skips notarization. Signature verification is always fatal; only the local
Gatekeeper assessment may warn and continue.

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
