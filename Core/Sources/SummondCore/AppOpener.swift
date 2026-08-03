import Foundation
import OSLog

public actor AppOpener {
  private let runtime: any AppRuntime
  private let logger: Logger
  private let verboseLogging: VerboseLoggingState
  private var inFlightBundleIDs: Set<String> = []

  public init(
    runtime: any AppRuntime,
    logger: Logger = SummondLoggers.opener,
    verboseLogging: VerboseLoggingState
  ) {
    self.runtime = runtime
    self.logger = logger
    self.verboseLogging = verboseLogging
  }

  public func open(_ binding: CompiledAppBinding) async {
    let bundleID = binding.identity.bundleIdentifier
    guard !inFlightBundleIDs.contains(bundleID) else {
      if verboseLogging.isEnabled {
        logger.debug(
          "[\(binding.binding.shortcut.description, privacy: .private)] skipping '\(bundleID, privacy: .private)', already in-flight"
        )
      }
      return
    }

    inFlightBundleIDs.insert(bundleID)
    let result = await runtime.open(
      identity: binding.identity, mode: binding.binding.target.mode)
    log(result, description: binding.binding.shortcut.description, bundleID: bundleID)
    inFlightBundleIDs.remove(bundleID)
  }

  private func log(_ result: OpenAppResult, description: String, bundleID: String) {
    switch result {
    case .launched:
      logger.info(
        "[\(description, privacy: .private)] launched '\(bundleID, privacy: .private)'"
      )
    case .activatedExistingWindow:
      logger.info(
        "[\(description, privacy: .private)] activated '\(bundleID, privacy: .private)' on the current space"
      )
    case .openedNewWindow:
      logger.info(
        "[\(description, privacy: .private)] opened new window for '\(bundleID, privacy: .private)'"
      )
    case .movedToCurrentSpace:
      logger.info(
        "[\(description, privacy: .private)] moved '\(bundleID, privacy: .private)' to the current space"
      )
    case .failed(let reason):
      logger.warning(
        "[\(description, privacy: .private)] \(bundleID, privacy: .private): \(reason, privacy: .private)"
      )
    }
  }
}
