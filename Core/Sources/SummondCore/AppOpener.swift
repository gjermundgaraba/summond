import Foundation
import OSLog

public actor AppOpener {
  private let runtime: any AppRuntime
  private let logger: Logger
  private let verboseLogging: Bool
  private var inFlightBundleIDs: Set<String> = []
  private var idleContinuations: [CheckedContinuation<Void, Never>] = []

  public init(
    runtime: any AppRuntime,
    logger: Logger = SummondLoggers.opener,
    verboseLogging: Bool = false
  ) {
    self.runtime = runtime
    self.logger = logger
    self.verboseLogging = verboseLogging
  }

  public func open(_ binding: CompiledAppBinding) {
    let bundleID = binding.identity.bundleIdentifier
    guard !inFlightBundleIDs.contains(bundleID) else {
      if verboseLogging {
        logger.debug(
          "[\(binding.description, privacy: .private)] skipping '\(bundleID, privacy: .private)', already in-flight"
        )
      }
      return
    }

    inFlightBundleIDs.insert(bundleID)

    Task(priority: .userInitiated) {
      let result = await self.runtime.open(
        identity: binding.identity, mode: binding.binding.app.mode)
      self.finish(bundleID: bundleID, result: result, description: binding.description)
    }
  }

  public func waitForIdle() async {
    guard !inFlightBundleIDs.isEmpty else { return }
    await withCheckedContinuation { continuation in
      idleContinuations.append(continuation)
    }
  }

  private func finish(bundleID: String, result: OpenAppResult, description: String) {
    log(result, description: description)
    inFlightBundleIDs.remove(bundleID)

    guard inFlightBundleIDs.isEmpty else {
      return
    }

    let continuations = idleContinuations
    idleContinuations.removeAll()
    for continuation in continuations {
      continuation.resume()
    }
  }

  private func log(_ result: OpenAppResult, description: String) {
    switch result {
    case .launched(let bundleIdentifier):
      logger.info(
        "[\(description, privacy: .private)] launched '\(bundleIdentifier, privacy: .private)'"
      )
    case .activatedExistingWindow(let bundleIdentifier):
      logger.info(
        "[\(description, privacy: .private)] activated '\(bundleIdentifier, privacy: .private)' on the current space"
      )
    case .openedNewWindow(let bundleIdentifier):
      logger.info(
        "[\(description, privacy: .private)] opened new window for '\(bundleIdentifier, privacy: .private)'"
      )
    case .movedToCurrentSpace(let bundleIdentifier):
      logger.info(
        "[\(description, privacy: .private)] moved '\(bundleIdentifier, privacy: .private)' to the current space"
      )
    case .failed(let bundleIdentifier, let reason):
      logger.warning(
        "[\(description, privacy: .private)] \(bundleIdentifier, privacy: .private): \(reason, privacy: .private)"
      )
    }
  }
}
