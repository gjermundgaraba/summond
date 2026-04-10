import CoreGraphics
import Testing

@testable import keybindd

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
}
