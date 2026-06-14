import CoreGraphics
import Foundation
import KeybinddCore

enum ShortcutFormatter {
  /// macOS renders modifier glyphs in the order Control, Option, Shift, Command
  /// regardless of how they are stored, so display order is defined here rather
  /// than borrowed from KeyCode's storage order.
  private static let displayOrderedModifiers: [(flag: CGEventFlags, symbol: String)] = [
    (.maskControl, "⌃"),
    (.maskAlternate, "⌥"),
    (.maskShift, "⇧"),
    (.maskCommand, "⌘"),
  ]

  private static let keySymbols: [String: String] = [
    "space": "Space",
    "return": "Return",
    "tab": "Tab",
    "escape": "Esc",
    "delete": "Delete",
    "forwarddelete": "Forward Delete",
    "up": "↑",
    "down": "↓",
    "left": "←",
    "right": "→",
    "home": "Home",
    "end": "End",
    "pageup": "Page Up",
    "pagedown": "Page Down",
    "minus": "-",
    "equal": "=",
    "leftbracket": "[",
    "rightbracket": "]",
    "backslash": "\\",
    "semicolon": ";",
    "quote": "'",
    "comma": ",",
    "period": ".",
    "slash": "/",
    "grave": "`",
  ]

  static func symbols(for shortcut: Shortcut) -> String {
    tokens(for: shortcut).joined()
  }

  static func tokens(for shortcut: Shortcut) -> [String] {
    let flags = KeyCode.resolveModifiers(shortcut.mods) ?? CGEventFlags()
    let modifierTokens =
      displayOrderedModifiers
      .filter { flags.contains($0.flag) }
      .map(\.symbol)
    return modifierTokens + [keyTitle(shortcut.key)]
  }

  static func tokens(for draft: ShortcutDraft) -> [String] {
    guard let shortcut = draft.shortcut else {
      return []
    }
    return tokens(for: shortcut)
  }

  static func keyTitle(_ key: String) -> String {
    if let symbol = keySymbols[key] {
      return symbol
    }
    if key.count == 1 {
      return key.uppercased()
    }
    if key.hasPrefix("f") {
      return key.uppercased()
    }
    return key
  }
}

extension AppOpenMode {
  var shortTitle: String {
    switch self {
    case .launch:
      "Launch"
    case .newWindow:
      "New Window"
    case .move:
      "Move"
    }
  }

  var title: String {
    switch self {
    case .launch:
      "Launch or focus"
    case .newWindow:
      "New window"
    case .move:
      "Move to current Space"
    }
  }

  var description: String {
    switch self {
    case .launch:
      "Opens the app, or brings its existing window to the front if it's already running."
    case .newWindow:
      "Opens a fresh window on this Space, even when the app is already running on another Space."
    case .move:
      "Pulls the app's existing windows from another Space onto this Space, then focuses it."
    }
  }
}
