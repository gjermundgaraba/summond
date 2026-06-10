# Architecture

keybindd is a macOS foreground daemon that intercepts global key events and opens or focuses applications based on a TOML config file.

## Layer Diagram

```
┌─────────────────────────────────────────────────────────┐
│  CLI (CLI.swift)                                        │
│  swift-argument-parser subcommands:                     │
│    start · stop · config {list,add,remove,validate}     │
└────────────┬────────────────────────────────────────────┘
             │
┌────────────▼────────────────────────────────────────────┐
│  Daemon (Daemon.swift)                                  │
│  CFRunLoop + CGEvent tap + signal handlers              │
├────────┬───────────────────┬────────────────────────────┤
│ Config  │                   │   App Opening              │
│ Pipeline│                   │   Pipeline                 │
└─────────┴───────────────────┴────────────────────────────┘
```

## Components

### CLI — `CLI.swift`

`@main` entry point using `swift-argument-parser`. Subcommands:

- **`start`** — creates a `Daemon` and calls `.start()`
- **`stop`** — reads the PID file, sends `SIGTERM`
- **`config list/add/remove/validate`** — config inspection/editing via `BindingConfigStore`
  - `config add` accepts either a bundle ID or an application path; application paths are resolved to bundle IDs before saving

### Daemon — `Daemon.swift`

Runtime core. On `start()`:

1. Acquires a PID file (`PidFile`) to enforce single-instance
2. Registers as an `.accessory` `NSApplication` (no Dock/menu-bar presence). This is required so WindowServer accepts the private space-move operation behind `move` mode; the run loop is still `CFRunLoopRun()`, not `NSApp.run()`.
3. Creates the config file if missing
4. Loads and compiles bindings into a `BindingSnapshot`
5. Installs signal handlers (`SIGTERM`/`SIGINT` → shutdown)
6. Installs a `CGEvent` tap intercepting all `keyDown` events
7. Runs `CFRunLoopRun()` on the main thread

If the initial config load fails, startup aborts. Config is loaded once at startup; to pick up changes, stop and restart the daemon.

When a key event arrives, the tap extracts the key code and modifier flags, queries `BindingState.match()`, and if matched, dispatches to `AppOpener.open()` and swallows the event.

Important behavior: matched shortcuts are consumed immediately. If app opening later fails asynchronously, the original key event is still swallowed.

### Config Pipeline

| File | Role |
|---|---|
| `BindingConfigDocument.swift` | Decodes the TOML `bindings` document via `swift-toml` and encodes `[AppBinding]` back to TOML. |
| `BindingConfigStore.swift` | `load` (parse + compile), `add` (compile, check duplicates, append), `remove` (by key or shortcut, with ambiguity detection). |
| `BindingCompiler.swift` | Transforms `AppBinding` (human-readable strings) into `CompiledAppBinding` (`CGKeyCode` + `CGEventFlags` + resolved `AppIdentity`). Produces a `BindingSnapshot` — a dictionary keyed by `CompiledShortcut` for O(1) event matching. |

### Domain Model — `AppBinding.swift`

- **`Shortcut`** — key name + modifier names (strings)
- **`AppTarget`** — bundle ID + `AppOpenMode`
- **`AppBinding`** — a `Shortcut` + `AppTarget`
- **`AppOpenMode`** — `.launch`, `.newWindow`, or `.move`; a single parser accepts both CLI form (`new-window`) and config form (`new_window`)
- Error enums: `BindingValidationError`, `BindingConfigError`, `BindingEditError`

### App Opening Pipeline

| File | Role |
|---|---|
| `AppRuntime.swift` | Protocols (`AppResolver`, `AppRuntime`) and types (`AppIdentity`, `OpenAppResult`, `RunningApplicationState`). Testability seam. |
| `MacOSAppRuntime.swift` | macOS implementation. `InstalledAppResolver` uses `NSWorkspace` to find apps. `MacOSAppRuntime` handles three modes: **launch** (via `NSWorkspace.openApplication`), **new_window** (checks for existing windows via `CGWindowListCopyWindowInfo`; if on another space, triggers "New Window" via the Dock menu, waits for a window to appear on the current space, then activates), and **move** (activates a window already on the current space; otherwise moves the app's existing windows here via `SpaceMover` and activates; launches if not running or windowless). Dock-menu, window-move, window-appearance, and activation failures are reported as logged app-open failures rather than crashes. |
| `DockMenuOpener.swift` | Accessibility-based "New Window" triggering. Finds the app in the Dock via the AX API, opens the context menu, locates the "New Window" item, and presses it. Includes retry logic for menu appearance timing. |
| `SpaceMover.swift` | Moves other apps' windows to the active Mission Control space via private SkyLight functions. Picks one of three mechanisms at startup: a bridged window-management operation (macOS 15+/26, the no-SIP path, located by scanning SkyLight's Mach-O symbol table since the function has internal linkage), the `SLSSpaceSetCompatID` + `SLSSetWindowListWorkspace` compat-ID workaround (macOS 12.7+/13.6+/14.5+), or direct `SLSMoveWindowsToManagedSpace` (older). All symbols are resolved at runtime so a missing one degrades to a logged failure. The active space is read via `SLSManagedDisplayGetCurrentSpace` on the menu-bar display. |

### AppOpener — `AppOpener.swift`

An `actor` wrapping `AppRuntime` with deduplication. Tracks in-flight bundle IDs so rapid repeated presses for the same app don't stack.

### KeyCode — `KeyCode.swift`

Static lookup tables mapping human-readable names to hardware codes:

- Keys: `"f5"`, `"space"`, `"a"` → `CGKeyCode`
- Modifiers: `"cmd"`/`"command"`, `"shift"`, `"alt"`/`"opt"`/`"option"`, `"ctrl"`/`"control"` → `CGEventFlags`

### Infrastructure

| File | Role |
|---|---|
| `PidFile.swift` | Single-instance enforcement via `flock()`. Writes the PID to `~/.config/keybindd/keybindd.pid`. Handles stale PID cleanup. |
| `Logging.swift` | Stderr logger with `debug`/`info`/`warning`/`error` levels. `debug` is gated behind `--verbose`. |
| `AppPaths.swift` | Default paths: config (`~/.config/keybindd/config.toml`) and PID file (`~/.config/keybindd/keybindd.pid`). |

## Key Press → App Activation

```
CGEvent tap (keyDown)
  → Daemon.handleKeyEvent()
    → extract CGKeyCode + CGEventFlags
    → BindingState.match(keyCode, modifiers)
    → if hit: CompiledAppBinding
      → AppOpener.open(binding)             [actor, deduplicates]
        → AppRuntime.open(identity, mode)
          → launch:      NSWorkspace.openApplication
          → new_window:
              window here?       → activate (or fail)
              running elsewhere? → DockMenuOpener → wait for window → activate (or fail)
              not running?       → launch
          → move:
              window here?         → activate (or fail)
              windows elsewhere?   → SpaceMover → wait for window → activate (or fail)
              not running/no win?  → launch
    → swallow event (return nil from tap)
```

## Concurrency / Threading

The runtime model is intentionally simple:

- `Daemon` is main-thread / main-run-loop owned.
- The event tap source is installed on the main run loop, so binding lookup is not contended across threads.
- `AppOpener` is an `actor`, which serializes app-open deduplication and completion bookkeeping.
- `MacOSAppRuntime` performs system integration asynchronously; activation/launch operations hop to the appropriate main-thread AppKit APIs when required.
- `PidFileStore` is the one explicitly lock-based component (`NSLock`), because PID-file acquisition/removal can be called from different contexts.

This means the hot path (`keyDown` → binding lookup) stays synchronous and cheap, while slower app-launch work is pushed into async code.

## Operational Requirements / Caveats

- **Accessibility permission is required** for the event tap and for Dock accessibility interactions.
- `new_window` depends on macOS/Dock accessibility behavior and on the target app exposing a usable **New Window** menu item in its Dock menu.
- `move` depends on private SkyLight window-server functions (no public API exists for moving another app's windows between spaces); if a future macOS removes them, moves fail as logged app-open failures.
- Some apps may not support opening a new window from the Dock menu, may localize the item unexpectedly, may fail activation, or may show no window even after launch; these cases surface as logged failures rather than crashes.
- Config validation/compilation is **machine-specific** because bundle IDs are resolved against apps installed on the current Mac.
- `start` is a **foreground** process; lifecycle control (`stop`) happens from another shell via signals and the PID file.

## Failure Semantics

- Startup fails fast on: PID-file conflicts, config creation failure, invalid/unresolvable initial config, or inability to install the event tap.
- App-opening failures are non-fatal; they are logged by `AppOpener`. This includes Dock-menu failures, window-move failures, missing windows on the current space, and activation failures in `new_window` and `move` modes.
- A matched binding consumes the triggering key even if the later open attempt fails.

## Dependencies

- [swift-argument-parser](https://github.com/apple/swift-argument-parser) — CLI parsing
- [swift-toml](https://github.com/mattt/swift-toml) — TOML config parsing and serialization

## Testability

The architecture is testable via protocol boundaries:

- **`AppResolver`** — stub to avoid real `NSWorkspace` lookups
- **`AppRuntime`** / **`MacOSAppRuntimeSystem`** — fake to avoid launching real apps
- **`PidFileStore`** — accepts injected `currentPID` and `processChecker` closures
- **`BindingCompiler`** / **`BindingConfigDocument`** — pure functions, directly unit-testable
