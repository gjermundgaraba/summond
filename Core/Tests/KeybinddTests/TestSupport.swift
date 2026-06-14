import CoreGraphics
import Foundation

@testable import KeybinddCore

final class TestAppRuntime: @unchecked Sendable, AppRuntime {
  private let lock = NSLock()
  private var shouldSuspendNextOpen = false
  private var pendingOpenContinuation: CheckedContinuation<OpenAppResult, Never>?
  private var resultsByBundleID: [String: OpenAppResult] = [:]
  private var openRequests: [(bundleID: String, mode: AppOpenMode)] = []

  func setResult(_ result: OpenAppResult, for bundleID: String) {
    lock.withLock {
      resultsByBundleID[bundleID] = result
    }
  }

  func suspendNextOpen() {
    lock.withLock {
      shouldSuspendNextOpen = true
    }
  }

  func open(identity: AppIdentity, mode: AppOpenMode) async -> OpenAppResult {
    let suspended = lock.withLock { () -> Bool in
      openRequests.append((identity.bundleIdentifier, mode))
      let value = shouldSuspendNextOpen
      shouldSuspendNextOpen = false
      return value
    }

    if suspended {
      return await withCheckedContinuation { continuation in
        lock.withLock {
          pendingOpenContinuation = continuation
        }
      }
    }

    return lock.withLock {
      resultsByBundleID[identity.bundleIdentifier]
        ?? .launched(bundleIdentifier: identity.bundleIdentifier)
    }
  }

  func completeOpen(with result: OpenAppResult) {
    let continuation = lock.withLock { () -> CheckedContinuation<OpenAppResult, Never>? in
      let continuation = pendingOpenContinuation
      pendingOpenContinuation = nil
      return continuation
    }
    continuation?.resume(returning: result)
  }

  func waitForPendingOpen() async {
    for _ in 0..<100 {
      if lock.withLock({ pendingOpenContinuation != nil }) {
        return
      }
      await Task.yield()
    }
  }

  func waitForOpenAttempts(_ expected: Int) async {
    for _ in 0..<100 {
      if openCount() == expected {
        return
      }
      await Task.yield()
    }
  }

  func openCount() -> Int {
    lock.withLock { openRequests.count }
  }
}

final class TestMacOSAppRuntimeSystem: @unchecked Sendable, MacOSAppRuntimeSystem {
  private let lock = NSLock()
  private var runningApps: [String: RunningApplicationState] = [:]
  private var appsOnCurrentSpace: Set<pid_t> = []
  private var windowIDsByPID: [pid_t: [CGWindowID]] = [:]
  private var waitResults: [pid_t: Bool] = [:]
  private var waitErrors: [pid_t: Error] = [:]
  private var launchResults: [String: String?] = [:]
  private var activationSuccess = true
  private var newWindowSuccess = true
  private var moveSuccess = true
  private var launchLog: [String] = []
  private var activatedBundleIDLog: [String] = []
  private var activationActivatesAllWindowsLog: [Bool] = []
  private var newWindowRequestLog: [String] = []
  private var moveRequestLog: [[CGWindowID]] = []

  func setRunningApp(_ app: RunningApplicationState?) {
    lock.withLock {
      guard let app else {
        runningApps.removeAll()
        return
      }
      runningApps[app.bundleIdentifier] = app
    }
  }

  func setAppOnCurrentSpace(processID: pid_t, present: Bool) {
    lock.withLock {
      if present {
        appsOnCurrentSpace.insert(processID)
      } else {
        appsOnCurrentSpace.remove(processID)
      }
    }
  }

  func setWaitForWindow(processID: pid_t, result: Bool) {
    lock.withLock {
      waitResults[processID] = result
      waitErrors[processID] = nil
    }
  }

  func setWaitForWindow(processID: pid_t, error: Error) {
    lock.withLock {
      waitErrors[processID] = error
    }
  }

  func setLaunchResult(for bundleID: String, error: String?) {
    lock.withLock {
      launchResults[bundleID] = error
    }
  }

  func setActivationSuccess(_ value: Bool) {
    lock.withLock {
      activationSuccess = value
    }
  }

  func setOpenNewWindowSuccess(_ value: Bool) {
    lock.withLock {
      newWindowSuccess = value
    }
  }

  func setWindowIDs(_ windowIDs: [CGWindowID], for processID: pid_t) {
    lock.withLock {
      windowIDsByPID[processID] = windowIDs
    }
  }

  func setMoveSuccess(_ value: Bool) {
    lock.withLock {
      moveSuccess = value
    }
  }

  func runningApplication(bundleIdentifier: String) -> RunningApplicationState? {
    lock.withLock { runningApps[bundleIdentifier] }
  }

  func hasWindowOnCurrentSpace(processID: pid_t) -> Bool {
    lock.withLock { appsOnCurrentSpace.contains(processID) }
  }

  func activateApplication(bundleIdentifier: String, activatesAllWindows: Bool) async -> Bool {
    lock.withLock {
      activatedBundleIDLog.append(bundleIdentifier)
      activationActivatesAllWindowsLog.append(activatesAllWindows)
      return activationSuccess
    }
  }

  func launchApplication(identity: AppIdentity) async -> String? {
    lock.withLock {
      launchLog.append(identity.bundleIdentifier)
      return launchResults[identity.bundleIdentifier] ?? nil
    }
  }

  func openNewWindow(for identity: AppIdentity) async -> Bool {
    lock.withLock {
      newWindowRequestLog.append(identity.bundleIdentifier)
      return newWindowSuccess
    }
  }

  func windowIDsOnAnySpace(processID: pid_t) -> [CGWindowID] {
    lock.withLock { windowIDsByPID[processID] ?? [] }
  }

  func moveWindowsToCurrentSpace(_ windowIDs: [CGWindowID], processID: pid_t) async -> Bool {
    lock.withLock {
      moveRequestLog.append(windowIDs)
      return moveSuccess
    }
  }

  func waitForWindowOnCurrentSpace(processID: pid_t) async throws -> Bool {
    let outcome = lock.withLock { () -> (Bool?, Error?) in
      (waitResults[processID], waitErrors[processID])
    }

    if let error = outcome.1 {
      throw error
    }

    return outcome.0 ?? true
  }

  func launchRequests() -> [String] {
    lock.withLock { launchLog }
  }

  func activatedBundleIDs() -> [String] {
    lock.withLock { activatedBundleIDLog }
  }

  func activationActivatesAllWindows() -> [Bool] {
    lock.withLock { activationActivatesAllWindowsLog }
  }

  func newWindowRequests() -> [String] {
    lock.withLock { newWindowRequestLog }
  }

  func moveRequests() -> [[CGWindowID]] {
    lock.withLock { moveRequestLog }
  }
}

struct TestAppResolver: AppResolver {
  let appsByBundleID: [String: AppIdentity]

  func resolve(bundleID: String) -> AppIdentity? {
    appsByBundleID[bundleID]
  }
}

func makeBinding(
  key: String = "f5",
  mods: [String] = [],
  bundleID: String = "com.apple.safari",
  mode: AppOpenMode = .launch
) throws -> AppBinding {
  AppBinding(
    shortcut: Shortcut(key: key, mods: mods),
    app: try AppTarget(bundleID: bundleID, mode: mode)
  )
}

func makeIdentity(bundleID: String = "com.apple.safari") -> AppIdentity {
  AppIdentity(
    bundleURL: URL(fileURLWithPath: "/Applications/\(bundleID).app"),
    bundleIdentifier: bundleID
  )
}

func makeCompiledBinding(
  key: String = "f5",
  mods: [String] = [],
  bundleID: String = "com.apple.safari",
  mode: AppOpenMode = .launch
) throws -> CompiledAppBinding {
  let binding = try makeBinding(key: key, mods: mods, bundleID: bundleID, mode: mode)
  return CompiledAppBinding(
    binding: binding,
    shortcut: try BindingCompiler.compileShortcut(binding.shortcut),
    identity: makeIdentity(bundleID: bundleID)
  )
}

private let workingDirectoryLock = NSLock()

func withTemporaryCurrentDirectory<T>(
  _ body: (URL) throws -> T
) throws -> T {
  try workingDirectoryLock.withLock {
    let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    let previousDirectory = FileManager.default.currentDirectoryPath
    let changed = FileManager.default.changeCurrentDirectoryPath(tempDirectory.path)
    precondition(changed, "failed to change current directory")

    defer {
      _ = FileManager.default.changeCurrentDirectoryPath(previousDirectory)
      try? FileManager.default.removeItem(at: tempDirectory)
    }

    return try body(tempDirectory)
  }
}
