import CoreGraphics
import Foundation

@testable import SummondCore

final class TestAppRuntime: @unchecked Sendable, AppRuntime {
  private let lock = NSLock()
  private var shouldSuspendNextOpen = false
  private var pendingOpenContinuation: CheckedContinuation<OpenAppResult, Never>?
  private var openRequests: [(bundleID: String, mode: AppOpenMode)] = []

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

    return .launched
  }

  func completeOpen(with result: OpenAppResult) {
    let continuation = lock.withLock { () -> CheckedContinuation<OpenAppResult, Never>? in
      let continuation = pendingOpenContinuation
      pendingOpenContinuation = nil
      return continuation
    }
    continuation?.resume(returning: result)
  }

  func waitForPendingOpen() async -> Bool {
    for _ in 0..<100 {
      if lock.withLock({ pendingOpenContinuation != nil }) {
        return true
      }
      await Task.yield()
    }
    return false
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
  private var newWindowRequestLog: [String] = []
  private var moveRequestLog: [[CGWindowID]] = []

  func setRunningApp(
    bundleID: String = "com.apple.safari",
    processID: pid_t,
    isTerminated: Bool = false
  ) {
    lock.withLock {
      runningApps[bundleID] = RunningApplicationState(
        processID: processID, isTerminated: isTerminated)
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

  func activateApplication(bundleIdentifier: String) async -> Bool {
    lock.withLock {
      activatedBundleIDLog.append(bundleIdentifier)
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
) throws -> StoredBinding {
  StoredBinding(
    shortcut: Shortcut(key: key, mods: mods),
    target: try AppTarget(bundleID: bundleID, mode: mode)
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
