import Carbon.HIToolbox
import CoreGraphics
import Testing

@testable import SummondCore

@MainActor
private final class TestHotKeySystem: HotKeySystem {
  var installHandlerSucceeds = true
  var failingKeyCodes: Set<UInt32> = []
  private(set) var registrations: [(keyCode: UInt32, carbonModifiers: UInt32, hotKeyID: UInt32)] =
    []
  private var dispatch: (@MainActor (UInt32) -> Void)?

  func installHandler(dispatch: @escaping @MainActor (UInt32) -> Void) -> Bool {
    guard installHandlerSucceeds else { return false }
    self.dispatch = dispatch
    return true
  }

  func register(keyCode: UInt32, carbonModifiers: UInt32, hotKeyID: UInt32) -> OSStatus {
    guard !failingKeyCodes.contains(keyCode) else {
      return OSStatus(eventHotKeyExistsErr)
    }
    registrations.append((keyCode, carbonModifiers, hotKeyID))
    return noErr
  }

  func unregisterAll() {
    registrations.removeAll()
  }

  func press(hotKeyID: UInt32) {
    dispatch?(hotKeyID)
  }
}

@MainActor
@Suite("Hot key engine")
struct HotKeyEngineTests {
  private func makeSnapshot(
    bindings: [(key: String, mods: [String], bundleID: String)] = [
      (key: "f5", mods: ["cmd"], bundleID: "com.apple.safari")
    ]
  ) throws -> BindingSnapshot {
    let resolver = TestAppResolver(
      appsByBundleID: Dictionary(
        uniqueKeysWithValues: bindings.map { ($0.bundleID, makeIdentity(bundleID: $0.bundleID)) }
      )
    )
    let compiled = try BindingCompiler.compile(
      try bindings.map { try makeBinding(key: $0.key, mods: $0.mods, bundleID: $0.bundleID) },
      appResolver: resolver
    )
    return compiled.snapshot
  }

  private func makeEngine(
    runtime: TestAppRuntime,
    system: TestHotKeySystem
  ) -> HotKeyEngine {
    HotKeyEngine(
      runtime: runtime,
      system: system,
      verboseLogging: VerboseLoggingState()
    )
  }

  @Test("Registers bindings once started and fires the action on dispatch")
  func registersAndFiresOnDispatch() async throws {
    let runtime = TestAppRuntime()
    let system = TestHotKeySystem()
    let engine = makeEngine(runtime: runtime, system: system)

    engine.start()
    engine.replaceSnapshot(try makeSnapshot(), verboseLogging: false)

    let registration = try #require(system.registrations.first)
    #expect(registration.keyCode == UInt32(try #require(KeyCode.resolve("f5"))))
    #expect(registration.carbonModifiers == UInt32(cmdKey))
    #expect(engine.isHandlerInstalled)
    #expect(engine.failedShortcuts.isEmpty)

    runtime.suspendNextOpen()
    system.press(hotKeyID: registration.hotKeyID)

    #expect(await runtime.waitForPendingOpen())
    runtime.completeOpen(with: .launched)
    #expect(runtime.openCount() == 1)
  }

  @Test("Replacing the snapshot re-registers and retires old hot key IDs")
  func replaceSnapshotReregisters() async throws {
    let runtime = TestAppRuntime()
    let system = TestHotKeySystem()
    let engine = makeEngine(runtime: runtime, system: system)

    engine.start()
    engine.replaceSnapshot(try makeSnapshot(), verboseLogging: false)
    let oldID = try #require(system.registrations.first).hotKeyID

    engine.replaceSnapshot(
      try makeSnapshot(bindings: [(key: "f6", mods: ["cmd"], bundleID: "com.apple.mail")]),
      verboseLogging: false
    )

    #expect(system.registrations.count == 1)
    let newID = try #require(system.registrations.first).hotKeyID
    #expect(newID != oldID)

    runtime.suspendNextOpen()
    system.press(hotKeyID: oldID)
    system.press(hotKeyID: newID)

    #expect(await runtime.waitForPendingOpen())
    runtime.completeOpen(with: .launched)
    #expect(runtime.openCount() == 1)
  }

  @Test("Reports failed registrations sorted and keeps the rest active")
  func reportsFailedRegistrations() throws {
    let system = TestHotKeySystem()
    system.failingKeyCodes = [
      UInt32(try #require(KeyCode.resolve("f6"))),
      UInt32(try #require(KeyCode.resolve("f8"))),
    ]
    let engine = makeEngine(runtime: TestAppRuntime(), system: system)

    engine.start()
    engine.replaceSnapshot(
      try makeSnapshot(bindings: [
        (key: "f8", mods: ["cmd"], bundleID: "com.apple.notes"),
        (key: "f5", mods: ["cmd"], bundleID: "com.apple.safari"),
        (key: "f6", mods: ["cmd"], bundleID: "com.apple.mail"),
      ]),
      verboseLogging: false
    )

    #expect(system.registrations.count == 1)
    #expect(engine.failedShortcuts == ["cmd+f6", "cmd+f8"])
  }

  @Test("A failed handler install is reported and registers nothing")
  func failedHandlerInstallRegistersNothing() throws {
    let system = TestHotKeySystem()
    system.installHandlerSucceeds = false
    let engine = makeEngine(runtime: TestAppRuntime(), system: system)

    engine.start()
    engine.replaceSnapshot(try makeSnapshot(), verboseLogging: false)

    #expect(!engine.isHandlerInstalled)
    #expect(system.registrations.isEmpty)
  }

  @Test("Reload updates shared verbose logging")
  func reloadUpdatesSharedVerboseLogging() {
    let verboseLogging = VerboseLoggingState()
    let engine = HotKeyEngine(
      runtime: TestAppRuntime(),
      system: TestHotKeySystem(),
      verboseLogging: verboseLogging
    )

    engine.replaceSnapshot(.empty, verboseLogging: true)

    #expect(verboseLogging.isEnabled)
  }

  @Test("Maps CGEvent modifier flags to Carbon modifiers")
  func mapsCarbonModifiers() {
    #expect(KeyCode.carbonModifiers(for: []) == 0)
    #expect(KeyCode.carbonModifiers(for: .maskCommand) == UInt32(cmdKey))
    #expect(
      KeyCode.carbonModifiers(for: [.maskCommand, .maskShift, .maskAlternate, .maskControl])
        == UInt32(cmdKey) | UInt32(shiftKey) | UInt32(optionKey) | UInt32(controlKey)
    )
  }
}
