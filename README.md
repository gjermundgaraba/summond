# Summond

Summond is a macOS app and background agent that summons app windows from a
global shortcut — it opens, focuses, or moves a target app's windows onto your
current Space. Summond edits shortcuts, the LaunchAgent intercepts
key events, and an optional menu bar item shows agent health.

## Requirements

- macOS 26.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.45.4+
- [Tart](https://tart.run/) for `make test-tart`
- Accessibility permission for the `Summond` entry that represents the
  bundled `SummondAgent` helper
- Input Monitoring permission for the `Summond` entry that represents the
  bundled `SummondAgent` helper
- Login Items approval for the bundled LaunchAgent when macOS asks for it

## Install

1. Drag `Summond.app` to `/Applications`.
2. Open `Summond.app`.
3. Click **Enable Service**.
4. If the service shows **Requires Approval**, open System Settings > General >
   Login Items & Extensions and approve Summond.
5. Grant Accessibility permission to the `Summond` helper entry in System
   Settings > Privacy & Security > Accessibility.
6. Grant Input Monitoring permission to the `Summond` helper entry in System
   Settings > Privacy & Security > Input Monitoring.

The app installs its service from inside the bundle with `SMAppService`. The
agent runs only in your Aqua login session.

## Configure Shortcuts

Use the shortcuts list in `Summond.app` to add, edit, or delete shortcuts.
You can search installed apps or choose a `.app` bundle manually. The shortcut
recorder accepts supported keys with optional modifiers. Function and navigation
keys may be used without modifiers; literal keys require Command, Option, or
Control so shortcuts cannot silently shadow normal typing.

Supported modifiers:

- `command`
- `shift`
- `option`
- `control`

Representative supported keys include letters, numbers, function keys
`f1`-`f20`, arrows, `home`, `end`, `pageup`, `pagedown`, `space`, `tab`,
`return`, `escape`, `delete`, and common punctuation.

### Shortcut Behaviors

**Switch to It** performs a normal app launch or activation.

**New Window** prefers a window on the current Space. If the app is already
running elsewhere, Summond asks the Dock for the app's **New Window** menu item,
waits for a window on the current Space, and then activates the app. If Dock
menu access, window creation, or activation fails, the shortcut is still
consumed and the failure is logged.

**Move Here** brings existing windows to the current Space when possible. It uses
private SkyLight window-server functions because macOS has no public API for
moving another app's windows between Spaces. On supported macOS 26+ systems,
this uses the bridged window-management path that works without disabling SIP.
If the underlying functions disappear in a future macOS release, the move is
logged as a non-fatal failure.

## Menu Bar Item

Enable the menu bar item from Summond. It is installed as the
bundled login item `SummondStatus.app` and shows agent reachability,
Accessibility, Input Monitoring, shortcut listener, and configuration state. Its
menu opens Summond and offers a contextual recovery action when attention is
needed.

## Troubleshooting

If the service shows **Requires Approval**, approve Summond in System Settings >
General > Login Items & Extensions.

If shortcuts stop working after rebuilding or re-signing the app, macOS may have
revoked Accessibility trust for the old signature. Reset it and grant permission
again:

```bash
tccutil reset Accessibility net.garaba.summond.agent
tccutil reset ListenEvent net.garaba.summond.agent
```

Stream logs from the app, agent, and status item:

```bash
log stream --predicate 'subsystem == "net.garaba.summond"'
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

Run the same test gate, plus the XCUITest UI suite, in a clean disposable Tart
VM:

```bash
make test-tart
```

`make test-tart` ensures a reusable Tart base VM named
`codex-macos-tahoe-xcodegen-base` exists, clones it to a disposable VM, mounts
this checkout at `/Volumes/My Shared Files/summond`, copies it to a guest-local
temp directory, then runs `make test ui-test` there. The XCUITest UI tests
(`make ui-test`) drive a real GUI app, so they run only inside the Tart VM and
are intentionally excluded from host `make test`. The disposable VM is stopped
and deleted after the run. Use `BASE_VM=<name>` to choose a different prepared
base.
If the base is missing, `scripts/tart-ensure-base.sh` creates it from
`ghcr.io/cirruslabs/macos-tahoe-xcode:latest` and installs XcodeGen.

The UI suite drives the real views, app model, and persistence (a Debug-only
harness injects fakes for XPC/SMAppService/catalog/store). SwiftUI scene windows
do not render under XCUITest in the Tart VM, so the harness hosts the real views
in AppKit windows; the production *scene* layer is therefore not covered by
these tests and remains manual-test-only — `WindowGroup`/`Window`/`Settings`
presentation, the menu commands (⌘N/⌘↩/⌦), the `summond://` deep link,
window placement/restoration, and `scenePhase` reactivation. `make ui-test`
refuses to run on a host Mac unless `ALLOW_HOST_UITESTS=1` is set (it drives a
real GUI); `make test-tart` sets it inside the VM.

Routine `make test` covers the agent XPC client/listener contract with an
anonymous-listener integration test and static LaunchAgent plist assertions.
`make smoke-tart` adds an unattended Tart VM smoke for launchctl spawn and a real
mach-service status round-trip. See [ARCHITECTURE.md](ARCHITECTURE.md) for the
full coverage boundary.

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
NOTARY_PROFILE=summond-notary \
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
make release
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for the bundle layout, XPC boundary,
storage format, and release signing flow.
