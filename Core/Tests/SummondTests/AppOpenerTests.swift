import Foundation
import Testing

@testable import SummondCore

@Suite("Dock menu opener")
struct DockMenuOpenerTests {
  @Test("Matches a title-only New Window item")
  func matchesTitleOnlyNewWindowItem() {
    #expect(
      DockMenuOpener.matchesNewWindowItem(
        title: "New Window", command: nil, modifiers: nil
      ))
  }

  @Test("Treats an indeterminate AX action as possibly completed")
  func acceptsCannotCompleteAction() {
    #expect(DockMenuOpener.actionMayHaveCompleted(.cannotComplete))
  }
}

@Suite("App opener")
struct AppOpenerTests {
  @Test("Open requests are deduped by bundle ID while in flight")
  func openRequestsAreDedupedByBundleID() async throws {
    let runtime = TestAppRuntime()
    runtime.suspendNextOpen()
    let opener = AppOpener(runtime: runtime, verboseLogging: VerboseLoggingState())
    let first = try makeCompiledBinding(bundleID: "com.apple.safari", mode: .launch)
    let second = try makeCompiledBinding(key: "f6", bundleID: "com.apple.safari", mode: .launch)

    let firstOpen = Task { await opener.open(first) }
    #expect(await runtime.waitForPendingOpen())
    await opener.open(second)

    #expect(runtime.openCount() == 1)

    runtime.completeOpen(with: .launched)
    await firstOpen.value

    await opener.open(second)
    #expect(runtime.openCount() == 2)
  }

  @Test("Failed opens clear in-flight bundle IDs")
  func failedOpensClearInFlightBundleIDs() async throws {
    let runtime = TestAppRuntime()
    runtime.suspendNextOpen()
    let opener = AppOpener(runtime: runtime, verboseLogging: VerboseLoggingState())
    let binding = try makeCompiledBinding(bundleID: "com.apple.safari", mode: .launch)

    let firstOpen = Task { await opener.open(binding) }
    #expect(await runtime.waitForPendingOpen())

    runtime.completeOpen(with: .failed(reason: "boom"))
    await firstOpen.value

    await opener.open(binding)
    #expect(runtime.openCount() == 2)
  }
}

@Suite("macOS app runtime")
struct MacOSAppRuntimeTests {
  @Test("Launch mode launches the app")
  func launchModeLaunchesTheApp() async {
    let system = TestMacOSAppRuntimeSystem()
    let runtime = MacOSAppRuntime(system: system)

    let result = await runtime.open(identity: makeIdentity(), mode: .launch)

    #expect(result == .launched)
    #expect(system.launchRequests() == ["com.apple.safari"])
    #expect(system.newWindowRequests().isEmpty)
    #expect(system.activatedProcessIDs().isEmpty)
  }

  @Test("New-window mode activates an existing window without opening a new one")
  func newWindowActivatesExistingWindow() async {
    let system = TestMacOSAppRuntimeSystem()
    system.setRunningApp(processID: 42)
    system.setAppOnCurrentSpace(processID: 42, present: true)
    let runtime = MacOSAppRuntime(system: system)

    let result = await runtime.open(identity: makeIdentity(), mode: .newWindow)

    #expect(result == .activatedExistingWindow)
    #expect(system.launchRequests().isEmpty)
    #expect(system.newWindowRequests().isEmpty)
    #expect(system.activatedProcessIDs() == [42])
  }

  @Test("New-window mode fails when activating an existing window fails")
  func newWindowFailsWhenExistingWindowActivationFails() async {
    let system = TestMacOSAppRuntimeSystem()
    system.setRunningApp(processID: 42)
    system.setAppOnCurrentSpace(processID: 42, present: true)
    system.setActivationSuccess(false)
    let runtime = MacOSAppRuntime(system: system)

    let result = await runtime.open(identity: makeIdentity(), mode: .newWindow)

    #expect(result == .failed(reason: "failed to activate existing window"))
    #expect(system.launchRequests().isEmpty)
    #expect(system.newWindowRequests().isEmpty)
    #expect(system.activatedProcessIDs() == [42])
  }

  @Test("New-window mode requests a new window for a running app off the current space")
  func newWindowRequestsNewWindowWhenNeeded() async {
    let system = TestMacOSAppRuntimeSystem()
    system.setRunningApp(processID: 42)
    system.setAppOnCurrentSpace(processID: 42, present: false)
    system.setWaitForWindow(processID: 42, result: true)
    let runtime = MacOSAppRuntime(system: system)

    let result = await runtime.open(identity: makeIdentity(), mode: .newWindow)

    #expect(result == .openedNewWindow)
    #expect(system.launchRequests().isEmpty)
    #expect(system.newWindowRequests() == ["com.apple.safari"])
    #expect(system.activatedProcessIDs() == [42])
  }

  @Test("New-window mode fails when activation after opening a new window fails")
  func newWindowFailsWhenNewWindowActivationFails() async {
    let system = TestMacOSAppRuntimeSystem()
    system.setRunningApp(processID: 42)
    system.setAppOnCurrentSpace(processID: 42, present: false)
    system.setWaitForWindow(processID: 42, result: true)
    system.setActivationSuccess(false)
    let runtime = MacOSAppRuntime(system: system)

    let result = await runtime.open(identity: makeIdentity(), mode: .newWindow)

    #expect(result == .failed(reason: "failed to activate app after opening new window"))
    #expect(system.launchRequests().isEmpty)
    #expect(system.newWindowRequests() == ["com.apple.safari"])
    #expect(system.activatedProcessIDs() == [42])
  }

  @Test("New-window mode launches when the app is not running")
  func newWindowLaunchesWhenAppIsNotRunning() async {
    let system = TestMacOSAppRuntimeSystem()
    let runtime = MacOSAppRuntime(system: system)

    let result = await runtime.open(identity: makeIdentity(), mode: .newWindow)

    #expect(result == .launched)
    #expect(system.launchRequests() == ["com.apple.safari"])
    #expect(system.newWindowRequests().isEmpty)
  }

  @Test("New-window mode fails when a new window never appears")
  func newWindowFailsWhenNewWindowDoesNotAppear() async {
    let system = TestMacOSAppRuntimeSystem()
    system.setRunningApp(processID: 42)
    system.setAppOnCurrentSpace(processID: 42, present: false)
    system.setWaitForWindow(processID: 42, result: false)
    let runtime = MacOSAppRuntime(system: system)

    let result = await runtime.open(identity: makeIdentity(), mode: .newWindow)

    #expect(result == .failed(reason: "new window did not appear on current space"))
    #expect(system.newWindowRequests() == ["com.apple.safari"])
    #expect(system.activatedProcessIDs().isEmpty)
  }

  @Test("New-window mode fails when waiting for a new window is cancelled")
  func newWindowFailsWhenWaitIsCancelled() async {
    struct WaitCancelled: Error {}

    let system = TestMacOSAppRuntimeSystem()
    system.setRunningApp(processID: 42)
    system.setAppOnCurrentSpace(processID: 42, present: false)
    system.setWaitForWindow(processID: 42, error: WaitCancelled())
    let runtime = MacOSAppRuntime(system: system)

    let result = await runtime.open(identity: makeIdentity(), mode: .newWindow)

    #expect(result == .failed(reason: "cancelled while waiting for new window"))
    #expect(system.newWindowRequests() == ["com.apple.safari"])
    #expect(system.activatedProcessIDs().isEmpty)
  }

  @Test("Move mode launches when the app is not running")
  func moveLaunchesWhenAppIsNotRunning() async {
    let system = TestMacOSAppRuntimeSystem()
    let runtime = MacOSAppRuntime(system: system)

    let result = await runtime.open(identity: makeIdentity(), mode: .move)

    #expect(result == .launched)
    #expect(system.launchRequests() == ["com.apple.safari"])
    #expect(system.moveRequests().isEmpty)
  }

  @Test("Move mode activates an existing window on the current space without moving anything")
  func moveActivatesExistingWindowOnCurrentSpace() async {
    let system = TestMacOSAppRuntimeSystem()
    system.setRunningApp(processID: 42)
    system.setAppOnCurrentSpace(processID: 42, present: true)
    system.setWindowIDs([7], for: 42)
    let runtime = MacOSAppRuntime(system: system)

    let result = await runtime.open(identity: makeIdentity(), mode: .move)

    #expect(result == .activatedExistingWindow)
    #expect(system.launchRequests().isEmpty)
    #expect(system.moveRequests().isEmpty)
    #expect(system.activatedProcessIDs() == [42])
  }

  @Test("Move mode moves windows from another space and activates the app")
  func moveMovesWindowsFromAnotherSpace() async {
    let system = TestMacOSAppRuntimeSystem()
    system.setRunningApp(processID: 42)
    system.setAppOnCurrentSpace(processID: 42, present: false)
    system.setWindowIDs([7, 8], for: 42)
    let runtime = MacOSAppRuntime(system: system)

    let result = await runtime.open(identity: makeIdentity(), mode: .move)

    #expect(result == .movedToCurrentSpace)
    #expect(system.launchRequests().isEmpty)
    #expect(system.newWindowRequests().isEmpty)
    #expect(system.moveRequests() == [[7, 8]])
    #expect(system.activatedProcessIDs() == [42])
  }

  @Test("Move mode launches when the app is running without windows")
  func moveLaunchesWhenAppHasNoWindows() async {
    let system = TestMacOSAppRuntimeSystem()
    system.setRunningApp(processID: 42)
    system.setAppOnCurrentSpace(processID: 42, present: false)
    let runtime = MacOSAppRuntime(system: system)

    let result = await runtime.open(identity: makeIdentity(), mode: .move)

    #expect(result == .launched)
    #expect(system.launchRequests() == ["com.apple.safari"])
    #expect(system.moveRequests().isEmpty)
  }

  @Test("Move mode fails when moving windows fails")
  func moveFailsWhenMovingWindowsFails() async {
    let system = TestMacOSAppRuntimeSystem()
    system.setRunningApp(processID: 42)
    system.setAppOnCurrentSpace(processID: 42, present: false)
    system.setWindowIDs([7], for: 42)
    system.setMoveSuccess(false)
    let runtime = MacOSAppRuntime(system: system)

    let result = await runtime.open(identity: makeIdentity(), mode: .move)

    #expect(result == .failed(reason: "failed to move windows to current space"))
    #expect(system.moveRequests() == [[7]])
    #expect(system.activatedProcessIDs().isEmpty)
  }

  @Test("Move mode fails when activation after moving windows fails")
  func moveFailsWhenActivationAfterMoveFails() async {
    let system = TestMacOSAppRuntimeSystem()
    system.setRunningApp(processID: 42)
    system.setAppOnCurrentSpace(processID: 42, present: false)
    system.setWindowIDs([7], for: 42)
    system.setActivationSuccess(false)
    let runtime = MacOSAppRuntime(system: system)

    let result = await runtime.open(identity: makeIdentity(), mode: .move)

    #expect(result == .failed(reason: "failed to activate app after moving windows"))
    #expect(system.moveRequests() == [[7]])
    #expect(system.activatedProcessIDs() == [42])
  }
}

@Suite("Installed app resolver")
struct InstalledAppResolverTests {
  @Test("Uses the bundle metadata bundle identifier")
  func usesBundleMetadataBundleIdentifier() throws {
    let bundleURL = try makeTestApplicationBundle()
    defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }

    let identity = InstalledAppResolver.identity(forApplicationURL: bundleURL)

    #expect(identity?.bundleURL == bundleURL.standardizedFileURL)
    #expect(identity?.bundleIdentifier == "com.apple.Safari")
  }
}

private func makeTestApplicationBundle() throws -> URL {
  let baseDirectory =
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let bundleURL = baseDirectory.appendingPathComponent("Safari.app")
  let contentsURL = bundleURL.appendingPathComponent("Contents")
  let infoPlistURL = contentsURL.appendingPathComponent("Info.plist")

  try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

  let infoPlist = ["CFBundleIdentifier": "com.apple.Safari"]
  let plistData = try PropertyListSerialization.data(
    fromPropertyList: infoPlist,
    format: .xml,
    options: 0
  )
  try plistData.write(to: infoPlistURL)

  return bundleURL
}
