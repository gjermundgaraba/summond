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

  func status() -> AgentStatus {
    let fields = reloader.statusFields()
    return AgentStatus(
      agentVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
      accessibilityGranted: AccessibilityTrust.isTrusted(prompt: false),
      shortcutsActive: engine.isHandlerInstalled,
      failedShortcuts: engine.failedShortcuts,
      configState: fields.configState,
      bindingCount: fields.bindingCount,
      lastReloadError: fields.lastReloadError,
      unresolvedBundleIDs: fields.unresolvedBundleIDs
    )
  }

  func loadConfiguration() {
    let result = reloader.reload()
    if let snapshot = result.snapshotToInstall {
      engine.replaceSnapshot(snapshot, verboseLogging: result.verboseLogging)
    } else if let error = result.lastReloadError {
      logger.warning("configuration reload failed, preserving previous snapshot: \(error)")
    }
  }

  func reloadConfiguration() -> AgentStatus {
    loadConfiguration()
    return status()
  }

  func requestAccessibilityPrompt() {
    _ = AccessibilityTrust.isTrusted(prompt: true)
  }
}

enum AccessibilityTrust {
  static func isTrusted(prompt: Bool) -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
  }
}
