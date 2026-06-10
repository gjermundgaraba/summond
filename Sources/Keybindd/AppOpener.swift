import Foundation

actor AppOpener {
  private let runtime: any AppRuntime
  private let logger: Logger
  private var inFlightBundleIDs: Set<String> = []
  private var idleContinuations: [CheckedContinuation<Void, Never>] = []

  init(runtime: any AppRuntime, logger: Logger = Logger()) {
    self.runtime = runtime
    self.logger = logger
  }

  func open(_ binding: CompiledAppBinding) {
    let bundleID = binding.identity.bundleIdentifier
    guard !inFlightBundleIDs.contains(bundleID) else {
      logger.debug("[\(binding.description)] skipping '\(bundleID)', already in-flight")
      return
    }

    inFlightBundleIDs.insert(bundleID)

    Task(priority: .userInitiated) {
      let result = await self.runtime.open(
        identity: binding.identity, mode: binding.binding.app.mode)
      self.finish(bundleID: bundleID, result: result, description: binding.description)
    }
  }

  func waitForIdle() async {
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
      logger.info("[\(description)] launched '\(bundleIdentifier)'")
    case .activatedExistingWindow(let bundleIdentifier):
      logger.info("[\(description)] activated '\(bundleIdentifier)' on the current space")
    case .openedNewWindow(let bundleIdentifier):
      logger.info("[\(description)] opened new window for '\(bundleIdentifier)'")
    case .movedToCurrentSpace(let bundleIdentifier):
      logger.info("[\(description)] moved '\(bundleIdentifier)' to the current space")
    case .failed(let bundleIdentifier, let reason):
      logger.warning("[\(description)] \(bundleIdentifier): \(reason)")
    }
  }
}
