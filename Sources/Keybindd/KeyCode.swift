import CoreGraphics

enum KeyCode {
  static func resolve(_ name: String) -> CGKeyCode? {
    keyMap[name.lowercased()]
  }

  static func resolveModifiers(_ names: [String]) -> CGEventFlags? {
    var flags = CGEventFlags()
    for name in names {
      guard let flag = modifierMap[name.lowercased()] else {
        return nil
      }
      flags.insert(flag)
    }
    return flags
  }

  private static let modifierMap: [String: CGEventFlags] = [
    "cmd": .maskCommand,
    "command": .maskCommand,
    "shift": .maskShift,
    "alt": .maskAlternate,
    "opt": .maskAlternate,
    "option": .maskAlternate,
    "ctrl": .maskControl,
    "control": .maskControl,
  ]

  static let relevantModifiersMask = CGEventFlags([
    .maskCommand, .maskShift, .maskAlternate, .maskControl,
  ])

  private static let keyMap: [String: CGKeyCode] = [
    "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02,
    "e": 0x0E, "f": 0x03, "g": 0x05, "h": 0x04,
    "i": 0x22, "j": 0x26, "k": 0x28, "l": 0x25,
    "m": 0x2E, "n": 0x2D, "o": 0x1F, "p": 0x23,
    "q": 0x0C, "r": 0x0F, "s": 0x01, "t": 0x11,
    "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07,
    "y": 0x10, "z": 0x06,

    "0": 0x1D, "1": 0x12, "2": 0x13, "3": 0x14,
    "4": 0x15, "5": 0x17, "6": 0x16, "7": 0x1A,
    "8": 0x1C, "9": 0x19,

    "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76,
    "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
    "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
    "f13": 0x69, "f14": 0x6B, "f15": 0x71, "f16": 0x6A,
    "f17": 0x40, "f18": 0x4F, "f19": 0x50, "f20": 0x5A,

    "space": 0x31,
    "return": 0x24, "enter": 0x24,
    "tab": 0x30,
    "escape": 0x35, "esc": 0x35,
    "delete": 0x33, "backspace": 0x33,
    "forwarddelete": 0x75,

    "up": 0x7E, "down": 0x7D, "left": 0x7B, "right": 0x7C,
    "home": 0x73, "end": 0x77,
    "pageup": 0x74, "pagedown": 0x79,

    "-": 0x1B, "minus": 0x1B,
    "=": 0x18, "equal": 0x18, "equals": 0x18,
    "[": 0x21, "leftbracket": 0x21,
    "]": 0x1E, "rightbracket": 0x1E,
    "\\": 0x2A, "backslash": 0x2A,
    ";": 0x29, "semicolon": 0x29,
    "'": 0x27, "quote": 0x27,
    ",": 0x2B, "comma": 0x2B,
    ".": 0x2F, "period": 0x2F,
    "/": 0x2C, "slash": 0x2C,
    "`": 0x32, "grave": 0x32,
  ]
}
