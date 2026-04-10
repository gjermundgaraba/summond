# keybindd

Foreground app-binding daemon for macOS 13+.

`keybindd` watches global key presses and opens or focuses macOS apps based on a TOML config file.

## Requirements

- macOS 13+
- Accessibility permission for `keybindd` in:
  - System Settings > Privacy & Security > Accessibility

Without Accessibility access, the event tap cannot be installed and the daemon will exit.

## Install

```bash
make install-binary
```

This builds a release binary and installs it to:

```text
~/.local/bin/keybindd
```

## Default paths

`keybindd` uses these paths by default:

- Config: `~/.config/keybindd/config.toml`
- PID file: `~/.config/keybindd/keybindd.pid`

The config file is created automatically when needed.

## Usage

Start the daemon in the foreground:

```bash
keybindd start
```

Enable verbose key event logging:

```bash
keybindd start --verbose
```

Stop the running daemon:

```bash
keybindd stop
```

The daemon loads the config once at startup. To apply config changes, stop and restart:

```bash
keybindd stop && keybindd start
```

Commands that operate on the config (`start`, `config list`, `config add`, `config remove`, `config validate`) also accept `--config <path>` to use a non-default config file.

## Managing config from the CLI

List bindings:

```bash
keybindd config list
```

Validate the current config against the machine:

```bash
keybindd config validate
```

Add a binding by bundle ID:

```bash
keybindd config add \
  --key f5 \
  --mods cmd,shift \
  --bundle-id com.apple.Safari \
  --mode current-space
```

Add a binding by application path:

```bash
keybindd config add \
  --key f6 \
  --mods cmd \
  --application-path /Applications/Safari.app \
  --mode launch
```

Remove a binding by exact shortcut:

```bash
keybindd config remove --key f5 --mods cmd,shift
```

Remove by key only:

```bash
keybindd config remove --key f6
```

If more than one binding uses the same key with different modifiers, `config remove --key ...` is rejected until you also pass `--mods`.

`keybindd config add` requires exactly one of:

- `--bundle-id`
- `--application-path`

When `--application-path` is used, `keybindd` reads the app bundle metadata and stores the resolved bundle identifier in the config.

## Config format

Example:

```toml
[[bindings]]
key = "f5"
mods = ["cmd", "shift"]

[bindings.app]
bundle_id = "com.apple.Safari"
mode = "current_space"

[[bindings]]
key = "f6"
mods = ["cmd"]

[bindings.app]
bundle_id = "com.apple.Terminal"
mode = "launch"
```

Each binding has:

- `key`: key name such as `a`, `space`, `return`, `f5`
- `mods`: zero or more modifiers
- `app.bundle_id`: target app bundle identifier
- `app.mode`: `launch` or `current_space`

Supported modifier names:

- `cmd` / `command`
- `shift`
- `alt` / `opt` / `option`
- `ctrl` / `control`

Representative supported keys include:

- letters: `a`-`z`
- numbers: `0`-`9`
- function keys: `f1`-`f20`
- navigation: `up`, `down`, `left`, `right`, `home`, `end`, `pageup`, `pagedown`
- common special keys: `space`, `tab`, `return`/`enter`, `escape`/`esc`, `delete`/`backspace`
- punctuation such as `-`, `=`, `[`, `]`, `\\`, `;`, `'`, `,`, `.`, `/`, `` ` ``

## Open modes

### `launch`

Performs a normal app launch/activation.

### `current_space`

Prefers opening or focusing a window on the current macOS space:

- if the app already has a window on the current space, `keybindd` tries to activate it
- if the app is running on another space, `keybindd` asks the Dock for a new window via the app's `New Window` menu item when possible, waits for that window to appear on the current space, then tries to activate the app
- if the app is not running, it is launched normally

If Dock menu access, window creation, or activation fails, the binding still consumes the key press and the failure is logged.

## Notes

- Only one daemon instance can run at a time.
- `start` runs in the foreground; use another terminal to run `stop`.
- Config validation fails if a binding uses an unknown key, unknown modifiers, an unknown mode, a duplicate shortcut, or a bundle ID that is not installed on the current machine.
- Config is loaded once at startup; there is no live reload. Restart the daemon to pick up changes.

## Development

```bash
make build
make test
make lint
make lint-fix
```
