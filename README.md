# keybindd

keybindd is a macOS app and background agent for global app shortcuts. The
preferences app edits shortcuts, the LaunchAgent intercepts key events, and an
optional menu bar item shows agent health.

## Requirements

- macOS 26.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.45.4+
- [Tart](https://tart.run/) for `make test-tart`
- Accessibility permission for the `Keybindd` entry that represents the
  bundled `KeybinddAgent` helper
- Input Monitoring permission for the `Keybindd` entry that represents the
  bundled `KeybinddAgent` helper
- Login Items approval for the bundled LaunchAgent when macOS asks for it

## Install

1. Drag `Keybindd.app` to `/Applications`.
2. Open `Keybindd.app`.
3. Click **Enable Service**.
4. If the service shows **Requires Approval**, open System Settings > General >
   Login Items & Extensions and approve Keybindd.
5. Grant Accessibility permission to the `Keybindd` helper entry in System
   Settings > Privacy & Security > Accessibility.
6. Grant Input Monitoring permission to the `Keybindd` helper entry in System
   Settings > Privacy & Security > Input Monitoring.

The app installs its service from inside the bundle with `SMAppService`. The
agent runs only in your Aqua login session.

## Configure Shortcuts

Use the bindings editor in `Keybindd.app` to add, edit, or delete shortcuts.
You can pick an installed app, choose a `.app` bundle manually, or paste a
bundle identifier. The shortcut recorder accepts supported keys with optional
modifiers. Modifier-less shortcuts are allowed; the app warns before saving
shortcuts that would shadow normal typing, such as bare or Shift-only literal
keys.

Supported modifiers:

- `command`
- `shift`
- `option`
- `control`

Representative supported keys include letters, numbers, function keys
`f1`-`f20`, arrows, `home`, `end`, `pageup`, `pagedown`, `space`, `tab`,
`return`, `escape`, `delete`, and common punctuation.

### Open Modes

`launch` performs a normal app launch or activation.

`new-window` prefers a window on the current Space. If the app is already
running elsewhere, keybindd asks the Dock for the app's **New Window** menu item,
waits for a window on the current Space, and then activates the app. If Dock
menu access, window creation, or activation fails, the shortcut is still
consumed and the failure is logged.

`move` brings existing windows to the current Space when possible. It uses
private SkyLight window-server functions because macOS has no public API for
moving another app's windows between Spaces. On supported macOS 26+ systems,
this uses the bridged window-management path that works without disabling SIP.
If the underlying functions disappear in a future macOS release, the move is
logged as a non-fatal failure.

## Menu Bar Item

Enable the menu bar item from the preferences app. It is installed as the
bundled login item `KeybinddStatus.app` and shows agent reachability,
Accessibility, Input Monitoring, shortcut listener, and configuration state. Its
menu can open preferences and reload the agent.

## Troubleshooting

If the service shows **Requires Approval**, approve Keybindd in System Settings >
General > Login Items & Extensions.

If shortcuts stop working after rebuilding or re-signing the app, macOS may have
revoked Accessibility trust for the old signature. Reset it and grant permission
again:

```bash
tccutil reset Accessibility net.garaba.keybindd.agent
tccutil reset ListenEvent net.garaba.keybindd.agent
```

Stream logs from the app, agent, and status item:

```bash
log stream --predicate 'subsystem == "net.garaba.keybindd"'
```

Useful service checks:

```bash
make project
make build
make test
```

## Build From Source

Show the available build, test, lint, and packaging commands:

```bash
make help
```

Generate the Xcode project:

```bash
make project
```

Build the Debug app:

```bash
make build
```

Run the full test suite:

```bash
make test
```

Run the same test gate in a clean disposable Tart VM:

```bash
make test-tart
```

`make test-tart` ensures a reusable Tart base VM named
`codex-macos-tahoe-xcodegen-base` exists, clones it to a disposable VM, mounts
this checkout at `/Volumes/My Shared Files/keybindd`, copies it to a guest-local
temp directory, then runs `make test` there. The disposable VM is stopped and
deleted after the run. Use `BASE_VM=<name>` to choose a different prepared base.
If the base is missing, `scripts/tart-ensure-base.sh` creates it from
`ghcr.io/cirruslabs/macos-tahoe-xcode:latest` and installs XcodeGen.

Run only Core package tests or only Xcode app tests:

```bash
make core-test
make app-test
```

Run formatting checks:

```bash
make lint
```

Create local release artifacts:

```bash
SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" make release-local
```

`make release-build` is an alias for `make release-local`; it creates a signed
Release app and zip without notarization for local validation.

Create Developer ID artifacts and submit them for notarization:

```bash
TEAM_ID=TEAMID \
NOTARY_PROFILE=keybindd-notary \
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
make release
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for the bundle layout, XPC boundary,
storage format, and release signing flow.

## v2 Breaking Changes

keybindd v2 is an app plus LaunchAgent, not the old foreground CLI/TOML daemon.
Configuration now lives as JSON data in the shared defaults suite
`net.garaba.keybindd.shared` and is edited through `Keybindd.app`.
