import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog

public struct InstalledAppResolver: AppResolver {
  public init() {}

  public func resolve(bundleID: String) -> AppIdentity? {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
      return nil
    }

    return Self.identity(forApplicationURL: url)
  }

  public static func identity(forApplicationPath path: String) -> AppIdentity? {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    return identity(forApplicationURL: url)
  }

  public static func identity(forApplicationURL url: URL) -> AppIdentity? {
    let standardizedURL = url.standardizedFileURL
    guard let bundleIdentifier = Bundle(url: standardizedURL)?.bundleIdentifier else {
      return nil
    }

    return AppIdentity(
      bundleURL: standardizedURL,
      bundleIdentifier: bundleIdentifier
    )
  }
}

protocol MacOSAppRuntimeSystem: Sendable {
  func runningApplication(bundleIdentifier: String) -> RunningApplicationState?
  func hasWindowOnCurrentSpace(processID: pid_t) -> Bool
  func windowIDsOnAnySpace(processID: pid_t) -> [CGWindowID]
  func activateApplication(bundleIdentifier: String, activatesAllWindows: Bool) async -> Bool
  func launchApplication(identity: AppIdentity) async -> String?
  func openNewWindow(for identity: AppIdentity) async -> Bool
  func moveWindowsToCurrentSpace(_ windowIDs: [CGWindowID], processID: pid_t) async -> Bool
  func waitForWindowOnCurrentSpace(processID: pid_t) async throws -> Bool
}

public struct MacOSAppRuntime: AppRuntime {
  private let system: any MacOSAppRuntimeSystem

  public init(logger: Logger = SummondLoggers.opener, verboseLogging: Bool = false) {
    self.system = LiveMacOSAppRuntimeSystem(logger: logger, verboseLogging: verboseLogging)
  }

  init(system: any MacOSAppRuntimeSystem) {
    self.system = system
  }

  public func open(identity: AppIdentity, mode: AppOpenMode) async -> OpenAppResult {
    switch mode {
    case .launch:
      return await launch(identity)
    case .newWindow:
      return await openOnCurrentSpace(identity)
    case .move:
      return await moveToCurrentSpace(identity)
    }
  }

  private func openOnCurrentSpace(_ identity: AppIdentity) async -> OpenAppResult {
    guard let app = runningApp(identity) else {
      return await launch(identity)
    }

    if system.hasWindowOnCurrentSpace(processID: app.processID) {
      return await activateExistingWindow(identity)
    }

    return await openNewWindowOnCurrentSpace(identity, app: app)
  }

  private func moveToCurrentSpace(_ identity: AppIdentity) async -> OpenAppResult {
    guard let app = runningApp(identity) else {
      return await launch(identity)
    }

    if system.hasWindowOnCurrentSpace(processID: app.processID) {
      return await activateExistingWindow(identity)
    }

    let windowIDs = system.windowIDsOnAnySpace(processID: app.processID)
    guard !windowIDs.isEmpty else {
      return await launch(identity)
    }

    guard await system.moveWindowsToCurrentSpace(windowIDs, processID: app.processID) else {
      return .failed(
        bundleIdentifier: identity.bundleIdentifier,
        reason: "failed to move windows to current space"
      )
    }

    guard await activateApplication(identity) else {
      return .failed(
        bundleIdentifier: identity.bundleIdentifier,
        reason: "failed to activate app after moving windows"
      )
    }

    return .movedToCurrentSpace(bundleIdentifier: identity.bundleIdentifier)
  }

  private func runningApp(_ identity: AppIdentity) -> RunningApplicationState? {
    guard
      let app = system.runningApplication(bundleIdentifier: identity.bundleIdentifier),
      !app.isTerminated
    else {
      return nil
    }

    return app
  }

  private func activateExistingWindow(_ identity: AppIdentity) async -> OpenAppResult {
    guard await activateApplication(identity) else {
      return .failed(
        bundleIdentifier: identity.bundleIdentifier,
        reason: "failed to activate existing window"
      )
    }

    return .activatedExistingWindow(bundleIdentifier: identity.bundleIdentifier)
  }

  private func openNewWindowOnCurrentSpace(
    _ identity: AppIdentity,
    app: RunningApplicationState
  ) async -> OpenAppResult {
    guard await system.openNewWindow(for: identity) else {
      return .failed(bundleIdentifier: identity.bundleIdentifier, reason: "dock menu failed")
    }

    let windowAppeared: Bool
    do {
      windowAppeared = try await system.waitForWindowOnCurrentSpace(processID: app.processID)
    } catch {
      return .failed(
        bundleIdentifier: identity.bundleIdentifier,
        reason: "cancelled while waiting for new window"
      )
    }

    guard windowAppeared else {
      return .failed(
        bundleIdentifier: identity.bundleIdentifier,
        reason: "new window did not appear on current space"
      )
    }

    guard await activateApplication(identity) else {
      return .failed(
        bundleIdentifier: identity.bundleIdentifier,
        reason: "failed to activate app after opening new window"
      )
    }

    return .openedNewWindow(bundleIdentifier: identity.bundleIdentifier)
  }

  private func activateApplication(_ identity: AppIdentity) async -> Bool {
    await system.activateApplication(
      bundleIdentifier: identity.bundleIdentifier,
      activatesAllWindows: true
    )
  }

  private func launch(_ identity: AppIdentity) async -> OpenAppResult {
    if let reason = await system.launchApplication(identity: identity) {
      return .failed(bundleIdentifier: identity.bundleIdentifier, reason: reason)
    }

    return .launched(bundleIdentifier: identity.bundleIdentifier)
  }
}

struct LiveMacOSAppRuntimeSystem: MacOSAppRuntimeSystem {
  private let dockMenuOpener: DockMenuOpener
  private let spaceMover: SpaceMover?
  private let logger: Logger
  private let verboseLogging: Bool
  private static let windowObserverTimeoutNanoseconds: UInt64 = 2_500_000_000
  private static let fallbackPollIntervalNanoseconds: UInt64 = 50_000_000
  private static let fallbackPollAttemptsAfterTimeout = 10
  private static let fallbackPollAttemptsWhenUnsupported = 60
  private static let movedWindowPollAttempts = 20

  init(logger: Logger = SummondLoggers.opener, verboseLogging: Bool = false) {
    self.dockMenuOpener = DockMenuOpener(logger: logger)
    self.spaceMover = SpaceMover(logger: SummondLoggers.spaces, verboseLogging: verboseLogging)
    self.logger = logger
    self.verboseLogging = verboseLogging
  }

  func runningApplication(bundleIdentifier: String) -> RunningApplicationState? {
    guard
      let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        .first
    else {
      return nil
    }

    return RunningApplicationState(
      bundleIdentifier: bundleIdentifier,
      processID: app.processIdentifier,
      isTerminated: app.isTerminated
    )
  }

  func activateApplication(bundleIdentifier: String, activatesAllWindows: Bool) async -> Bool {
    guard
      let app = NSRunningApplication.runningApplications(
        withBundleIdentifier: bundleIdentifier
      )
      .first
    else {
      logger.warning(
        "[runtime] activateApplication: no running instance found for '\(bundleIdentifier)'"
      )
      return false
    }

    let activated = await MainActor.run {
      var options: NSApplication.ActivationOptions = []
      if activatesAllWindows {
        options.insert(.activateAllWindows)
      }
      return app.activate(options: options)
    }
    if !activated {
      logger.warning(
        "[runtime] activateApplication: activation failed for '\(bundleIdentifier)'"
      )
    }
    return activated
  }

  func launchApplication(identity: AppIdentity) async -> String? {
    do {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        let configuration = NSWorkspace.OpenConfiguration()
        DispatchQueue.main.async {
          NSWorkspace.shared.openApplication(
            at: identity.bundleURL,
            configuration: configuration
          ) { _, error in
            if let error {
              continuation.resume(throwing: error)
            } else {
              continuation.resume()
            }
          }
        }
      }
      return nil
    } catch {
      return "failed to open '\(identity.bundleIdentifier)': \(error.localizedDescription)"
    }
  }

  func openNewWindow(for identity: AppIdentity) async -> Bool {
    await dockMenuOpener.openNewWindow(for: identity)
  }

  func hasWindowOnCurrentSpace(processID: pid_t) -> Bool {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
    else {
      return false
    }

    return windowList.contains { Self.standardWindowID(in: $0, processID: processID) != nil }
  }

  func windowIDsOnAnySpace(processID: pid_t) -> [CGWindowID] {
    // .optionAll includes windows on other spaces (they are simply off-screen);
    // layer 0 filters out status items, overlays, and other non-standard windows.
    let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
    guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
    else {
      return []
    }

    return windowList.compactMap { Self.standardWindowID(in: $0, processID: processID) }
  }

  private static func standardWindowID(
    in window: [String: Any],
    processID: pid_t
  ) -> CGWindowID? {
    guard
      let ownerPID = window[kCGWindowOwnerPID as String] as? NSNumber,
      ownerPID.int32Value == processID,
      let layer = window[kCGWindowLayer as String] as? NSNumber,
      layer.intValue == 0,
      let number = window[kCGWindowNumber as String] as? NSNumber,
      let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
      let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
      !bounds.isEmpty
    else {
      return nil
    }

    return CGWindowID(number.uint32Value)
  }

  func moveWindowsToCurrentSpace(_ windowIDs: [CGWindowID], processID: pid_t) async -> Bool {
    guard let spaceMover else {
      logger.warning("[runtime] SkyLight unavailable, cannot move windows between spaces")
      return false
    }

    guard spaceMover.moveWindowsToActiveSpace(windowIDs) else {
      return false
    }

    let appeared = try? await pollForWindowOnCurrentSpace(
      processID: processID,
      attempts: Self.movedWindowPollAttempts
    )
    return appeared ?? false
  }

  func waitForWindowOnCurrentSpace(processID: pid_t) async throws -> Bool {
    if hasWindowOnCurrentSpace(processID: processID) {
      return true
    }

    let observer = await MainActor.run {
      WindowAppearanceObserver(
        processID: processID,
        hasWindowOnCurrentSpace: self.hasWindowOnCurrentSpace(processID:),
        logger: logger,
        verboseLogging: verboseLogging
      )
    }
    let observation = await observer.wait(timeoutNanoseconds: Self.windowObserverTimeoutNanoseconds)
    switch observation {
    case .appeared:
      return true
    case .timedOut:
      if verboseLogging {
        logger.debug(
          "[runtime] AX window observation timed out for PID \(processID), falling back to polling"
        )
      }
      return try await pollForWindowOnCurrentSpace(
        processID: processID,
        attempts: Self.fallbackPollAttemptsAfterTimeout
      )
    case .unsupported:
      if verboseLogging {
        logger.debug(
          "[runtime] AX window observation unsupported for PID \(processID), falling back to polling"
        )
      }
      return try await pollForWindowOnCurrentSpace(
        processID: processID,
        attempts: Self.fallbackPollAttemptsWhenUnsupported
      )
    }
  }

  private func pollForWindowOnCurrentSpace(processID: pid_t, attempts: Int) async throws -> Bool {
    for _ in 0..<attempts {
      if hasWindowOnCurrentSpace(processID: processID) {
        return true
      }

      try await Task.sleep(nanoseconds: Self.fallbackPollIntervalNanoseconds)
    }

    return false
  }
}

private enum WindowObservationResult {
  case appeared
  case timedOut
  case unsupported
}

@MainActor
private final class WindowAppearanceObserver {
  private let processID: pid_t
  private let hasWindowOnCurrentSpace: @Sendable (pid_t) -> Bool
  private let logger: Logger
  private let verboseLogging: Bool
  private var observer: AXObserver?
  private var applicationElement: AXUIElement?
  private var continuation: CheckedContinuation<WindowObservationResult, Never>?
  private var timeoutTask: Task<Void, Never>?
  private var finished = false

  init(
    processID: pid_t,
    hasWindowOnCurrentSpace: @escaping @Sendable (pid_t) -> Bool,
    logger: Logger,
    verboseLogging: Bool
  ) {
    self.processID = processID
    self.hasWindowOnCurrentSpace = hasWindowOnCurrentSpace
    self.logger = logger
    self.verboseLogging = verboseLogging
  }

  func wait(timeoutNanoseconds: UInt64) async -> WindowObservationResult {
    if hasWindowOnCurrentSpace(processID) {
      return .appeared
    }

    guard setupObserver() else {
      return .unsupported
    }

    if hasWindowOnCurrentSpace(processID) {
      cleanup()
      return .appeared
    }

    return await withCheckedContinuation { continuation in
      self.continuation = continuation
      timeoutTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
        await MainActor.run {
          self?.finish(.timedOut)
        }
      }
    }
  }

  private func setupObserver() -> Bool {
    let applicationElement = AXUIElementCreateApplication(processID)
    var unmanagedObserver: AXObserver?
    let createResult = AXObserverCreate(
      processID,
      windowObserverCallback,
      &unmanagedObserver
    )
    guard createResult == .success, let observer = unmanagedObserver else {
      if verboseLogging {
        logger.debug(
          "[runtime] AXObserverCreate failed for PID \(self.processID): \(createResult.rawValue)"
        )
      }
      return false
    }

    self.observer = observer
    self.applicationElement = applicationElement
    CFRunLoopAddSource(
      CFRunLoopGetMain(),
      AXObserverGetRunLoopSource(observer),
      .commonModes
    )

    var registeredCount = 0
    for notification in Self.notifications {
      let result = AXObserverAddNotification(
        observer,
        applicationElement,
        notification as CFString,
        Unmanaged.passUnretained(self).toOpaque()
      )
      switch result {
      case .success, .notificationAlreadyRegistered:
        registeredCount += 1
      case .notificationUnsupported:
        if verboseLogging {
          logger.debug(
            "[runtime] AX notification unsupported for PID \(self.processID): \(notification)"
          )
        }
      default:
        if verboseLogging {
          logger.debug(
            "[runtime] AXObserverAddNotification failed for PID \(self.processID): \(notification) (\(result.rawValue))"
          )
        }
      }
    }

    guard registeredCount > 0 else {
      cleanup()
      return false
    }

    return true
  }

  fileprivate func handleNotification(_ notification: String) {
    if verboseLogging {
      logger.debug("[runtime] received AX notification for PID \(self.processID): \(notification)")
    }

    if hasWindowOnCurrentSpace(processID) {
      finish(.appeared)
    }
  }

  private func finish(_ result: WindowObservationResult) {
    guard !finished else {
      return
    }
    finished = true

    timeoutTask?.cancel()
    timeoutTask = nil

    let continuation = continuation
    self.continuation = nil
    cleanup()
    continuation?.resume(returning: result)
  }

  private func cleanup() {
    if let observer {
      CFRunLoopRemoveSource(
        CFRunLoopGetMain(),
        AXObserverGetRunLoopSource(observer),
        .commonModes
      )
    }

    applicationElement = nil
    observer = nil
  }

  private static let notifications: [String] = [
    kAXWindowCreatedNotification,
    kAXMainWindowChangedNotification,
    kAXFocusedWindowChangedNotification,
  ]
}

private func windowObserverCallback(
  observer: AXObserver,
  element: AXUIElement,
  notification: CFString,
  refcon: UnsafeMutableRawPointer?
) {
  _ = observer
  _ = element

  guard let refcon else {
    return
  }

  let notificationName = notification as String
  let windowObserver = Unmanaged<WindowAppearanceObserver>.fromOpaque(refcon)
    .takeUnretainedValue()
  Task { @MainActor in
    windowObserver.handleNotification(notificationName)
  }
}
