import CoreGraphics

public enum KeyCode {
  public static func resolve(_ name: String) -> CGKeyCode? {
    keyMap[name.lowercased()]
  }

  public static func name(for keyCode: CGKeyCode) -> String? {
    canonicalKeyNamesByCode[keyCode]
  }

  public static func resolveModifiers(_ names: [String]) -> CGEventFlags? {
    var flags = CGEventFlags()
    for name in names {
      guard let flag = modifierMap[name.lowercased()] else {
        return nil
      }
      flags.insert(flag)
    }
    return flags
  }

  /// Returns canonical modifier names in display/storage order.
  ///
  /// Aliases such as command/cmd, option/alt, and control/ctrl resolve to the
  /// same flags. The persisted recorder spelling is deliberately stable:
  /// cmd, shift, alt, ctrl.
  public static func modifierNames(for flags: CGEventFlags) -> [String] {
    canonicalModifierOrder.compactMap { name, flag in
      flags.contains(flag) ? name : nil
    }
  }

  public static let relevantModifiersMask = CGEventFlags([
    .maskCommand, .maskShift, .maskAlternate, .maskControl,
  ])

  /// Whether a key name or alias produces literal text when typed (letters,
  /// digits, space, and printable punctuation). Such a key, bound with no
  /// modifiers or with Shift alone, would shadow normal typing system-wide.
  public static func producesLiteralText(_ keyName: String) -> Bool {
    guard let code = resolve(keyName), let canonicalName = name(for: code) else {
      return false
    }
    return literalTextCanonicalKeyNames.contains(canonicalName)
  }

  private static let canonicalModifierOrder: [(name: String, flag: CGEventFlags)] = [
    ("cmd", .maskCommand),
    ("shift", .maskShift),
    ("alt", .maskAlternate),
    ("ctrl", .maskControl),
  ]

  private static let modifierAliases: [(names: [String], flag: CGEventFlags)] = [
    (["cmd", "command"], .maskCommand),
    (["shift"], .maskShift),
    (["alt", "opt", "option"], .maskAlternate),
    (["ctrl", "control"], .maskControl),
  ]

  private static let modifierMap: [String: CGEventFlags] = {
    Dictionary(
      uniqueKeysWithValues: modifierAliases.flatMap { aliases, flag in
        aliases.map { ($0, flag) }
      }
    )
  }()

  /// Key aliases are grouped with the first spelling as the canonical
  /// recorder/persistence spelling for that hardware key code.
  private static let keyAliases: [(names: [String], code: CGKeyCode)] = [
    (["a"], 0x00), (["b"], 0x0B), (["c"], 0x08), (["d"], 0x02),
    (["e"], 0x0E), (["f"], 0x03), (["g"], 0x05), (["h"], 0x04),
    (["i"], 0x22), (["j"], 0x26), (["k"], 0x28), (["l"], 0x25),
    (["m"], 0x2E), (["n"], 0x2D), (["o"], 0x1F), (["p"], 0x23),
    (["q"], 0x0C), (["r"], 0x0F), (["s"], 0x01), (["t"], 0x11),
    (["u"], 0x20), (["v"], 0x09), (["w"], 0x0D), (["x"], 0x07),
    (["y"], 0x10), (["z"], 0x06),

    (["0"], 0x1D), (["1"], 0x12), (["2"], 0x13), (["3"], 0x14),
    (["4"], 0x15), (["5"], 0x17), (["6"], 0x16), (["7"], 0x1A),
    (["8"], 0x1C), (["9"], 0x19),

    (["f1"], 0x7A), (["f2"], 0x78), (["f3"], 0x63), (["f4"], 0x76),
    (["f5"], 0x60), (["f6"], 0x61), (["f7"], 0x62), (["f8"], 0x64),
    (["f9"], 0x65), (["f10"], 0x6D), (["f11"], 0x67), (["f12"], 0x6F),
    (["f13"], 0x69), (["f14"], 0x6B), (["f15"], 0x71), (["f16"], 0x6A),
    (["f17"], 0x40), (["f18"], 0x4F), (["f19"], 0x50), (["f20"], 0x5A),

    (["space"], 0x31),
    (["return", "enter"], 0x24),
    (["tab"], 0x30),
    (["escape", "esc"], 0x35),
    (["delete", "backspace"], 0x33),
    (["forwarddelete"], 0x75),

    (["up"], 0x7E), (["down"], 0x7D), (["left"], 0x7B), (["right"], 0x7C),
    (["home"], 0x73), (["end"], 0x77),
    (["pageup"], 0x74), (["pagedown"], 0x79),

    (["minus", "-"], 0x1B),
    (["equal", "=", "equals"], 0x18),
    (["leftbracket", "["], 0x21),
    (["rightbracket", "]"], 0x1E),
    (["backslash", "\\"], 0x2A),
    (["semicolon", ";"], 0x29),
    (["quote", "'"], 0x27),
    (["comma", ","], 0x2B),
    (["period", "."], 0x2F),
    (["slash", "/"], 0x2C),
    (["grave", "`"], 0x32),
  ]

  /// Canonical names whose key produces literal text: single-character names
  /// (letters and digits), space, and the printable punctuation keys.
  private static let literalTextCanonicalKeyNames: Set<String> = {
    var names = Set(keyAliases.map(\.names[0]).filter { $0.count == 1 })
    names.formUnion([
      "space", "minus", "equal", "leftbracket", "rightbracket", "backslash",
      "semicolon", "quote", "comma", "period", "slash", "grave",
    ])
    return names
  }()

  private static let keyMap: [String: CGKeyCode] = {
    Dictionary(
      uniqueKeysWithValues: keyAliases.flatMap { aliases, code in
        aliases.map { ($0, code) }
      }
    )
  }()

  private static let canonicalKeyNamesByCode: [CGKeyCode: String] = {
    Dictionary(
      uniqueKeysWithValues: keyAliases.map { aliases, code in
        (code, aliases[0])
      })
  }()
}
