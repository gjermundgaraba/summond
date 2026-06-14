@preconcurrency import ApplicationServices
import Foundation
import KeybinddCore
import OSLog

@MainActor
final class AgentSupervisor {
  private let engine: KeyEventEngine
  private let reloader: AgentConfigurationReloader
  private let logger: Logger
  private var engineStartupTask: Task<Void, Never>?

  init(
    store: any ConfigurationStore,
    appResolver: any AppResolver,
    engine: KeyEventEngine,
    logger: Logger = KeybinddLoggers.agent
  ) {
    self.engine = engine
    self.reloader = AgentConfigurationReloader(store: store, appResolver: appResolver)
    self.logger = logger
  }

  func bootstrap() {
    _ = reloadConfiguration()
  }

  func reloadConfiguration() -> AgentStatus {
    let result = reloader.reload()
    if let snapshot = result.snapshotToInstall {
      engine.replaceSnapshot(snapshot, verboseLogging: result.verboseLogging)
    } else if let error = result.lastReloadError {
      logger.warning("configuration reload failed, preserving previous snapshot: \(error)")
    }

    attemptEngineStart()
    startEngineStartupPollingIfNeeded()
    return makeStatus()
  }

  func makeStatus() -> AgentStatus {
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

  func requestAccessibilityPrompt() {
    _ = AccessibilityTrust.isTrusted(prompt: true)
    attemptEngineStart()
    startEngineStartupPollingIfNeeded()
  }

  func requestInputMonitoringPrompt() {
    _ = InputMonitoringTrust.isTrusted(prompt: true)
    attemptEngineStart()
    startEngineStartupPollingIfNeeded()
  }

  private func attemptEngineStart() {
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

    do {
      try engine.start()
    } catch {
      logger.warning("event tap start failed: \(error.localizedDescription)")
    }
  }

  private func startEngineStartupPollingIfNeeded() {
    // Poll until the event tap is installed. This covers both waiting for the
    // user to grant Accessibility and retrying a transient tap-creation failure
    // (start() throwing even though permission is granted), so the agent
    // recovers without depending on a later reload.
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

        attemptEngineStart()
        if engine.status.isTapInstalled {
          stopEngineStartupPolling()
          return
        }
      }
    }
  }

  private func stopEngineStartupPolling() {
    engineStartupTask?.cancel()
    engineStartupTask = nil
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
