@preconcurrency import ApplicationServices
import Foundation
import OSLog
import SummondCore

@MainActor
final class AgentSupervisor {
  private let engine: KeyEventEngine
  private let reloader: AgentConfigurationReloader
  private let logger: Logger
  private let restartThrottle: RestartThrottle
  private let launchHistory: [Double]
  private var engineStartupTask: Task<Void, Never>?

  init(
    store: any ConfigurationStore,
    appResolver: any AppResolver,
    engine: KeyEventEngine,
    restartThrottle: RestartThrottle = RestartThrottle(),
    launchHistory: [Double] = [],
    logger: Logger = SummondLoggers.agent
  ) {
    self.engine = engine
    self.reloader = AgentConfigurationReloader(store: store, appResolver: appResolver)
    self.logger = logger
    self.restartThrottle = restartThrottle
    self.launchHistory = launchHistory
  }

  // Whether the crash-loop breaker currently permits installing the tap.
  // Re-evaluated each call against an advancing clock, so a tripped breaker
  // recovers once the launch burst ages out of the throttle window.
  private var restartThrottleAllowsTap: Bool {
    restartThrottle.shouldInstallTap(
      launches: launchHistory,
      now: Date().timeIntervalSince1970
    )
  }

  func status() async -> AgentStatus {
    await attemptEngineStart()
    startEngineStartupPollingIfNeeded()
    return makeStatus()
  }

  func loadConfiguration() {
    let result = reloader.reload()
    if let snapshot = result.snapshotToInstall {
      engine.replaceSnapshot(snapshot, verboseLogging: result.verboseLogging)
    } else if let error = result.lastReloadError {
      logger.warning("configuration reload failed, preserving previous snapshot: \(error)")
    }
  }

  func reloadConfiguration() async -> AgentStatus {
    loadConfiguration()
    return await status()
  }

  private func makeStatus() -> AgentStatus {
    let fields = reloader.statusFields()
    let engineStatus = engine.status
    let accessibilityGranted = AccessibilityTrust.isTrusted(prompt: false)
    let inputMonitoringGranted = InputMonitoringTrust.isTrusted(prompt: false)
    return AgentStatus(
      agentVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
      accessibilityGranted: accessibilityGranted,
      inputMonitoringGranted: inputMonitoringGranted,
      tapActive: engineStatus.isTapInstalled && engineStatus.isTapEnabled,
      tapFailureReason: tapFailureReason(
        accessibilityGranted: accessibilityGranted,
        inputMonitoringGranted: inputMonitoringGranted,
        engineStatus: engineStatus
      ),
      configState: fields.configState,
      bindingCount: fields.bindingCount,
      lastReloadError: fields.lastReloadError,
      unresolvedBundleIDs: fields.unresolvedBundleIDs
    )
  }

  func requestAccessibilityPrompt() async {
    _ = AccessibilityTrust.isTrusted(prompt: true)
    await attemptEngineStart()
    startEngineStartupPollingIfNeeded()
  }

  func requestInputMonitoringPrompt() async {
    _ = InputMonitoringTrust.isTrusted(prompt: true)
    await attemptEngineStart()
    startEngineStartupPollingIfNeeded()
  }

  private func attemptEngineStart() async {
    guard restartThrottleAllowsTap else {
      logger.fault("event tap installation deferred: restart loop detected")
      return
    }

    let accessibilityGranted = AccessibilityTrust.isTrusted(prompt: false)
    guard accessibilityGranted else {
      logger.info("accessibility permission is not granted; event tap not started")
      return
    }

    let inputMonitoringGranted = InputMonitoringTrust.isTrusted(prompt: false)
    guard inputMonitoringGranted else {
      logger.info("input monitoring permission is not granted; event tap not started")
      return
    }

    await engine.start()
  }

  private func startEngineStartupPollingIfNeeded() {
    // Poll until the event tap is installed. This covers waiting for the user to
    // grant Accessibility, retrying a transient tap-creation failure, and waiting
    // out a tripped restart-loop breaker -- each retry re-checks the throttle, so
    // the agent recovers without depending on a later reload or restart.
    guard !engine.status.isTapInstalled, engineStartupTask == nil else {
      return
    }

    engineStartupTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(nanoseconds: 5_000_000_000)
        } catch {
          return
        }

        guard let self, !Task.isCancelled else {
          return
        }

        await attemptEngineStart()
        if engine.status.isTapInstalled {
          engineStartupTask = nil
          return
        }
      }
    }
  }

  private func tapFailureReason(
    accessibilityGranted: Bool,
    inputMonitoringGranted: Bool,
    engineStatus: KeyEventEngineStatus
  ) -> EventTapFailureReason? {
    guard accessibilityGranted else {
      return .accessibilityDenied
    }
    guard inputMonitoringGranted else {
      return .inputMonitoringDenied
    }
    if !restartThrottleAllowsTap {
      return .restartLoopDetected
    }
    if engineStatus.isTapInstalled && engineStatus.isTapEnabled {
      return nil
    }
    if engineStatus.wasDisabledByTimeout {
      return .disabledByTimeout
    }
    if engineStatus.wasDisabledByUserInput {
      return .disabledByUserInput
    }
    if !engineStatus.isTapInstalled {
      return .installationFailed
    }
    return nil
  }
}

enum AccessibilityTrust {
  static func isTrusted(prompt: Bool) -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
  }
}

enum InputMonitoringTrust {
  static func isTrusted(prompt: Bool) -> Bool {
    if prompt {
      return CGRequestListenEventAccess()
    }
    return CGPreflightListenEventAccess()
  }
}
