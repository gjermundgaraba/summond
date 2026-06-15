import CoreGraphics
import Testing

@testable import SummondCore

@MainActor
@Suite("Key event engine")
struct KeyEventEngineTests {
  private func makeEngine(runtime: TestAppRuntime) throws -> KeyEventEngine {
    let resolver = TestAppResolver(appsByBundleID: [
      "com.apple.safari": makeIdentity(bundleID: "com.apple.safari")
    ])
    let snapshot = try BindingCompiler.compileBindings(
      [try makeBinding(key: "f5", mods: ["cmd"], bundleID: "com.apple.safari")],
      appResolver: resolver
    )
    return KeyEventEngine(snapshot: snapshot, runtime: runtime)
  }

  private func keyDown(_ name: String, autorepeat: Bool) throws -> CGEvent {
    let keyCode = try #require(KeyCode.resolve(name))
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true))
    event.flags = .maskCommand
    if autorepeat {
      event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
    }
    return event
  }

  private func waitForOpen(_ runtime: TestAppRuntime, count target: Int) async -> Bool {
    for _ in 0..<200 {
      if runtime.openCount() >= target {
        return true
      }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return false
  }

  @Test("Fires the action once for an initial key press and swallows the event")
  func firesOnceOnInitialPress() async throws {
    let runtime = TestAppRuntime()
    let engine = try makeEngine(runtime: runtime)

    let result = engine.handleKeyEvent(.keyDown, try keyDown("f5", autorepeat: false))

    #expect(result == nil)  // a matched binding consumes the event
    #expect(await waitForOpen(runtime, count: 1))
    #expect(runtime.openCount() == 1)
  }

  @Test("Swallows autorepeat key-downs without re-firing the action")
  func swallowsAutorepeatWithoutFiring() async throws {
    let runtime = TestAppRuntime()
    let engine = try makeEngine(runtime: runtime)

    let result = engine.handleKeyEvent(.keyDown, try keyDown("f5", autorepeat: true))

    #expect(result == nil)  // still consumed so it never leaks to the focused app
    #expect(runtime.openCount() == 0)
  }

  @Test("Passes through key events that match no binding")
  func passesThroughUnmatchedKeys() async throws {
    let runtime = TestAppRuntime()
    let engine = try makeEngine(runtime: runtime)

    let result = engine.handleKeyEvent(.keyDown, try keyDown("f6", autorepeat: false))

    #expect(result != nil)  // unmatched events are forwarded untouched
    #expect(runtime.openCount() == 0)
  }
}
