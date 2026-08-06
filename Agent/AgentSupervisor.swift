@preconcurrency import ApplicationServices
import Foundation
import OSLog
import SummondCore

@MainActor
final class AgentSupervisor {
  private let engine: HotKeyEngine
  private let reloader: AgentConfigurationReloader
  private let logger: Logger

  init(
    store: any ConfigurationStore,
    appResolver: any AppResolver,
    engine: HotKeyEngine,
    logger: Logger = SummondLoggers.agent
  ) {
    self.engine = engine
    self.reloader = AgentConfigurationReloader(store: store, appResolver: appResolver)
    self.logger = logger
  }

  /// Installs the hot-key handler and loads the initial configuration. Hot-key
  /// registration needs no permissions, so there is nothing to gate or poll.
  func start() {
    engine.start()
    loadConfiguration()
  }

  func status() async -> AgentStatus {
    engine.start()
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
    return AgentStatus(
      agentVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
      accessibilityGranted: AccessibilityTrust.isTrusted(prompt: false),
      accessibilityRequired: fields.accessibilityRequired,
      shortcutsActive: engineStatus.isHandlerInstalled,
      failedShortcuts: engineStatus.failedShortcuts,
      configState: fields.configState,
      bindingCount: fields.bindingCount,
      lastReloadError: fields.lastReloadError,
      unresolvedBundleIDs: fields.unresolvedBundleIDs
    )
  }

  func requestAccessibilityPrompt() async {
    _ = AccessibilityTrust.isTrusted(prompt: true)
  }
}

enum AccessibilityTrust {
  static func isTrusted(prompt: Bool) -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
  }
}
