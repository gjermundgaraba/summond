import AppKit
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
  func activateApplication(bundleIdentifier: String) async -> Bool
  func launchApplication(identity: AppIdentity) async -> String?
  func openNewWindow(for identity: AppIdentity) async -> Bool
  func moveWindowsToCurrentSpace(_ windowIDs: [CGWindowID], processID: pid_t) async -> Bool
  func waitForWindowOnCurrentSpace(processID: pid_t) async throws -> Bool
}

public struct MacOSAppRuntime: AppRuntime {
  private let system: any MacOSAppRuntimeSystem

  public init(
    logger: Logger = SummondLoggers.opener,
    verboseLogging: VerboseLoggingState
  ) {
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
      return .failed(reason: "failed to move windows to current space")
    }

    guard await activateApplication(identity) else {
      return .failed(reason: "failed to activate app after moving windows")
    }

    return .movedToCurrentSpace
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
      return .failed(reason: "failed to activate existing window")
    }

    return .activatedExistingWindow
  }

  private func openNewWindowOnCurrentSpace(
    _ identity: AppIdentity,
    app: RunningApplicationState
  ) async -> OpenAppResult {
    guard await system.openNewWindow(for: identity) else {
      return .failed(reason: "dock menu failed")
    }

    let windowAppeared: Bool
    do {
      windowAppeared = try await system.waitForWindowOnCurrentSpace(processID: app.processID)
    } catch {
      return .failed(reason: "cancelled while waiting for new window")
    }

    guard windowAppeared else {
      return .failed(reason: "new window did not appear on current space")
    }

    guard await activateApplication(identity) else {
      return .failed(reason: "failed to activate app after opening new window")
    }

    return .openedNewWindow
  }

  private func activateApplication(_ identity: AppIdentity) async -> Bool {
    await system.activateApplication(bundleIdentifier: identity.bundleIdentifier)
  }

  private func launch(_ identity: AppIdentity) async -> OpenAppResult {
    if let reason = await system.launchApplication(identity: identity) {
      return .failed(reason: reason)
    }

    return .launched
  }
}

struct LiveMacOSAppRuntimeSystem: MacOSAppRuntimeSystem {
  private let dockMenuOpener: DockMenuOpener
  private let spaceMover: SpaceMover?
  private let logger: Logger
  private static let windowPollIntervalNanoseconds: UInt64 = 100_000_000
  private static let newWindowPollAttempts = 31
  private static let movedWindowPollAttempts = 11

  init(
    logger: Logger = SummondLoggers.opener,
    verboseLogging: VerboseLoggingState
  ) {
    self.dockMenuOpener = DockMenuOpener(logger: logger)
    self.spaceMover = SpaceMover(logger: SummondLoggers.spaces, verboseLogging: verboseLogging)
    self.logger = logger
  }

  func runningApplication(bundleIdentifier: String) -> RunningApplicationState? {
    guard
      let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        .first
    else {
      return nil
    }

    return RunningApplicationState(
      processID: app.processIdentifier,
      isTerminated: app.isTerminated
    )
  }

  func activateApplication(bundleIdentifier: String) async -> Bool {
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
      app.activate(options: .activateAllWindows)
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
    guard let spaceMover else {
      return false
    }

    let windowIDs = windowIDsOnAnySpace(processID: processID)
    return spaceMover.anyWindowOnActiveSpace(windowIDs)
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
    // ponytail: 100 ms polling keeps a 3 s ceiling; restore AX events only if measured latency needs it.
    try await pollForWindowOnCurrentSpace(
      processID: processID,
      attempts: Self.newWindowPollAttempts
    )
  }

  private func pollForWindowOnCurrentSpace(processID: pid_t, attempts: Int) async throws -> Bool {
    for attempt in 0..<attempts {
      if hasWindowOnCurrentSpace(processID: processID) {
        return true
      }

      if attempt + 1 < attempts {
        try await Task.sleep(nanoseconds: Self.windowPollIntervalNanoseconds)
      }
    }

    return false
  }
}
