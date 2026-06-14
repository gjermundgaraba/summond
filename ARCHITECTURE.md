# Architecture

keybindd is a macOS preferences app, LaunchAgent, status item, and shared core
library for global app shortcuts.

## Component Diagram

```
┌──────────────────────────┐        keybindd:// URLs
│ KeybinddStatus.app       │ ─────────────────────────┐
│ menu bar login item      │                          │
└────────────┬─────────────┘                          │
             │ XPC status/reload                      │
             ▼                                        ▼
┌──────────────────────────┐   SMAppService   ┌──────────────────────────┐
│ KeybinddAgent            │ ◀──────────────▶ │ Keybindd.app             │
│ LaunchAgent + listener   │                  │ preferences + service UI │
└────────────┬─────────────┘                  └────────────┬─────────────┘
             │                                             │
             └──────────────┬──────────────────────────────┘
                            ▼
                ┌──────────────────────────┐
                │ KeybinddCore             │
                │ config, compiler, XPC,   │
                │ engine, app opening      │
                └────────────┬─────────────┘
                             ▼
                UserDefaults suite
                net.garaba.keybindd.shared
```

## Components

### `Keybindd.app`

SwiftUI preferences app with bundle identifier `net.garaba.keybindd`.

- Edits stored bindings and verbose logging.
- Registers/unregisters the LaunchAgent with
  `SMAppService.agent(plistName: "net.garaba.keybindd.agent.plist")`.
- Registers/unregisters the menu bar login item with
  `SMAppService.loginItem(identifier: "net.garaba.keybindd.ui")`.
- Handles `keybindd://` URLs from the status item.
- Talks to the agent over Mach XPC service
  `net.garaba.keybindd.agent.xpc`.

### `KeybinddAgent`

LaunchAgent embedded as a faceless helper app bundle at
`Contents/Resources/KeybinddAgent.app` (bundle identifier
`net.garaba.keybindd.agent`, `LSUIElement`). It is a bundle rather than a bare
executable so that the Accessibility permission it requests displays as
"Keybindd" with the app icon — TCC shows the requesting bundle's display name
and icon, and a bare tool would show the raw executable name and a generic
icon. The LaunchAgent plist's `BundleProgram` points at
`Contents/Resources/KeybinddAgent.app/Contents/MacOS/KeybinddAgent`.

- Runs in the user's Aqua session.
- Loads configuration from the shared defaults suite.
- Installs a global `CGEvent` tap after Accessibility and Input Monitoring
  permissions are granted.
- Exports XPC status, reload, Accessibility-prompt, and Input Monitoring-prompt
  requests.
- Uses `KeepAlive` crash-only semantics: launchd restarts it after an
  unsuccessful exit, but it is not a polling supervisor.

### `KeybinddStatus.app`

Menu bar login item embedded at
`Contents/Library/LoginItems/KeybinddStatus.app` with bundle identifier
`net.garaba.keybindd.ui`.

- Shows agent reachability, Accessibility, Input Monitoring, shortcut listener,
  and configuration state.
- Sends status and reload requests through the same agent XPC service.
- Opens the preferences app with `keybindd://` URLs for user actions.

### `KeybinddCore`

SwiftPM library shared by all targets. It contains the configuration model,
JSON defaults store, binding compiler, XPC protocol/codecs, status mapping,
event engine, app-opening runtime, Dock menu integration, and Space-moving
runtime.

## Configuration Data Flow

```
Preferences draft
  → validate shortcut, duplicate, mode, bundle-id shape
  → save JSON data to UserDefaults suite net.garaba.keybindd.shared
  → XPC reloadConfiguration()
  → agent lenient compile
      resolved apps become active bindings
      missing bundle IDs become unresolvedBundleIDs
      hard invalid config preserves previous snapshot
  → @MainActor snapshot swap in KeyEventEngine
```

The UI validates before save. The agent validates again when it reloads because
the current machine's installed apps can change after the UI saves.

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

`new-window` checks whether the app already has a window on the current Space.
If not, and the app is running elsewhere, the runtime asks the Dock accessibility
menu for **New Window**, waits for a new current-Space window, and activates the
app. Failures are logged and are non-fatal.

`move` checks for current-Space windows first. If windows exist on another
Space, it moves them to the current Space and activates the app. Moving relies
on private SkyLight functions resolved at runtime. On supported macOS 26+
systems, keybindd uses the bridged window-management operation that does not
require disabling SIP.

## Concurrency Model

- `AgentSupervisor` and `KeyEventEngine` are `@MainActor`.
- The event tap source is installed on the main run loop, so snapshot lookup is
  not contended.
- XPC calls enter on Foundation-managed queues and hop to `@MainActor` before
  touching supervisor or engine state.
- `AppOpener` is an actor that deduplicates in-flight opens per bundle ID.
- Storage wrappers that can be called from multiple contexts use `NSLock`.
- Slow app-opening work is async; the key-event hot path stays synchronous.

## Failure Semantics

- Missing Accessibility or Input Monitoring permission prevents event tap
  installation. The agent stays alive, polls trust state, and starts the engine
  when both permissions are present.
- Event tap creation failure is logged and surfaced through status.
- Corrupt stored JSON, unsupported schema versions, or structurally invalid
  configuration are reported as configuration problems.
- A hard invalid reload preserves the previous active snapshot.
- Fresh storage is not an error; the default configuration is empty.
- Missing target apps produce `unresolvedBundleIDs`; resolvable bindings remain
  active.
- Dock menu, window creation, window move, and activation failures are logged
  app-open failures, not process crashes.
- The LaunchAgent plist uses `KeepAlive` with `SuccessfulExit = false`, so
  launchd restarts crash exits but does not restart intentional successful
  exits.

## Storage Format

Configuration is JSON encoded `KeybinddConfigurationV1` stored as `Data` in:

- suite: `net.garaba.keybindd.shared`
- key: `configuration.v1`

Top-level fields:

- `schemaVersion`
- `bindings`
- `verboseLogging`

Each binding stores a stable UUID, a shortcut (`key`, `mods`), and a target
(`bundleID`, `mode`). The codec distinguishes fresh storage from corrupt data:
missing data returns `.fresh(.empty)`, while undecodable data, unsupported schema
versions, and invalid data return `.corrupt(...)`.

## XPC Boundary

The agent listens on Mach service `net.garaba.keybindd.agent.xpc`. The exported
protocol supports:

- `status`
- `reloadConfiguration`
- `requestAccessibilityPrompt`
- `requestInputMonitoringPrompt`

For signed builds, both sides install
`NSXPCConnection.setCodeSigningRequirement(_:)` requirements. The listener pins
incoming clients to the agent's own team identifier and exact allowed client
bundle identifiers: `net.garaba.keybindd` and `net.garaba.keybindd.ui`. The app
and status item pin the remote service to the same team identifier and exact
`net.garaba.keybindd.agent` bundle identifier. The team identifier is read at
runtime with `SecCodeCopySelf`/`SecCodeCopySigningInformation`, so Apple
Development and Developer ID builds work for whichever team signed the bundle.
Unsigned or ad-hoc debug builds have no team identifier; the app logs a warning
and skips the remote requirement, while the agent only skips the incoming-client
requirement in debug builds. Release agents reject connections when no team
identifier can be derived.

## Packaging Layout

XcodeGen creates three targets and the main app post-build script assembles this
bundle layout:

```text
Keybindd.app/
  Contents/
    MacOS/Keybindd
    Resources/KeybinddAgent.app
    Library/
      LaunchAgents/net.garaba.keybindd.agent.plist
      LoginItems/KeybinddStatus.app
```

The LaunchAgent plist declares:

- `Label`: `net.garaba.keybindd.agent`
- `BundleProgram`: `Contents/Resources/KeybinddAgent.app/Contents/MacOS/KeybinddAgent`
- `MachServices`: `net.garaba.keybindd.agent.xpc`
- `LimitLoadToSessionType`: `Aqua`
- `RunAtLoad`: `true`
- `KeepAlive.SuccessfulExit`: `false`
- `AssociatedBundleIdentifiers`: `net.garaba.keybindd`

When a development team or release team ID is available, the build and release
flows also add a generated `SpawnConstraint` with:

- `team-identifier`: the signing team ID
- `signing-identifier`: `net.garaba.keybindd.agent`

## Signing And Notarization

Distribution is Developer ID outside the Mac App Store. Hardened runtime is
enabled, the app sandbox is disabled, and no target currently needs custom
entitlements.

`scripts/release.sh` uses a Release build plus manual re-sign flow because the
bundle contains a nested login item and a LaunchAgent executable. Signing order
is innermost first:

1. `Contents/Library/LoginItems/KeybinddStatus.app`
2. `Contents/Resources/KeybinddAgent.app`
3. `Keybindd.app`

Every signing command uses `--options runtime --timestamp --force`. Release mode
requires a Developer ID Application identity, a team ID, and a notarytool
keychain profile; it zips with `ditto --keepParent`, submits with
`notarytool --wait`, staples, validates, and reruns verification. Local mode
signs with the provided identity, skips notarization, and treats trust-policy
verification failures as warnings.

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

Run the full repository test suite with:

```bash
make test
```
