import CoreGraphics
import Testing

@testable import KeybinddCore

@Suite("KeyCode resolution")
struct KeyCodeTests {
  @Test("Resolves representative keys case-insensitively")
  func representativeKeys() {
    #expect(KeyCode.resolve("A") == 0x00)
    #expect(KeyCode.resolve("Space") == 0x31)
    #expect(KeyCode.resolve("F5") == 0x60)
    #expect(KeyCode.resolve("left") == 0x7B)
  }

  @Test("Returns nil for unknown keys")
  func unknownKey() {
    #expect(KeyCode.resolve("nonexistent") == nil)
    #expect(KeyCode.resolve("") == nil)
  }

  @Test("Resolves modifier flags")
  func modifiers() {
    let cmdShift = KeyCode.resolveModifiers(["cmd", "shift"])
    #expect(cmdShift != nil)
    #expect(cmdShift!.contains(.maskCommand))
    #expect(cmdShift!.contains(.maskShift))
  }

  @Test("Returns nil for unknown modifiers")
  func unknownModifier() {
    #expect(KeyCode.resolveModifiers(["meta"]) == nil)
    #expect(KeyCode.resolveModifiers(["cmd", "super"]) == nil)
  }

  @Test("Empty modifiers returns empty flags")
  func emptyModifiers() {
    let flags = KeyCode.resolveModifiers([])
    #expect(flags != nil)
    #expect(flags == CGEventFlags())
  }

  @Test("Every key alias reverse-maps to a canonical key that resolves to the same code")
  func keyReverseLookupRoundTripsAliases() throws {
    for name in KeyCode.allKeyNames {
      let code = try #require(KeyCode.resolve(name), "Expected \(name) to resolve")
      let canonicalName = try #require(KeyCode.name(for: code))

      #expect(KeyCode.resolve(canonicalName) == code)
    }
  }

  @Test("Every modifier alias reverse-maps to canonical modifiers that resolve to the same flags")
  func modifierReverseLookupRoundTripsAliases() throws {
    for name in KeyCode.allModifierNames {
      let flags = try #require(KeyCode.resolveModifiers([name]), "Expected \(name) to resolve")
      let canonicalNames = KeyCode.modifierNames(for: flags)

      #expect(KeyCode.resolveModifiers(canonicalNames) == flags)
    }
  }

  @Test("Classifies literal-text keys for the typing-shadow warning")
  func classifiesLiteralTextKeys() {
    // Letters, digits, space, and punctuation produce literal text.
    for key in ["a", "z", "0", "9", "space", "minus", "slash", "grave"] {
      #expect(KeyCode.producesLiteralText(key), "\(key) should produce literal text")
    }
    // Control and navigation keys do not.
    for key in ["f1", "return", "tab", "escape", "delete", "up", "home", "pageup"] {
      #expect(!KeyCode.producesLiteralText(key), "\(key) should not produce literal text")
    }
    // Classification is case-insensitive.
    #expect(KeyCode.producesLiteralText("A"))
    for alias in ["-", "=", "[", "]", "\\", ";", "'", ",", ".", "/", "`"] {
      #expect(KeyCode.producesLiteralText(alias), "\(alias) should produce literal text")
    }
  }

  @Test("Recorder-style key code and flags round-trip through canonical names")
  func recorderStyleRoundTrip() throws {
    let originalFlags = CGEventFlags([.maskCommand, .maskShift, .maskAlternate])
    let originalCode = try #require(KeyCode.resolve("f5"))

    let keyName = try #require(KeyCode.name(for: originalCode))
    let modifierNames = KeyCode.modifierNames(for: originalFlags)

    #expect(KeyCode.resolve(keyName) == originalCode)
    #expect(KeyCode.resolveModifiers(modifierNames) == originalFlags)
    #expect(modifierNames == ["cmd", "shift", "alt"])
  }
}
