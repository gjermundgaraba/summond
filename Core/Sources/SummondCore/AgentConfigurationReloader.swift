import Foundation

public struct AgentConfigurationReloadResult: Sendable {
  public let snapshotToInstall: BindingSnapshot?
  public let verboseLogging: Bool
  public let lastReloadError: String?

}

public final class AgentConfigurationReloader: @unchecked Sendable {
  private let store: any ConfigurationStore
  private let appResolver: any AppResolver
  private let lock = NSLock()
  private var currentBindingCount = 0
  private var currentConfigState: AgentConfigurationState = .fresh
  private var currentVerboseLogging = false
  private var currentLastReloadError: String?
  private var currentUnresolvedBundleIDs: [String] = []

  public init(
    store: any ConfigurationStore,
    appResolver: any AppResolver
  ) {
    self.store = store
    self.appResolver = appResolver
  }

  public func reload() -> AgentConfigurationReloadResult {
    do {
      guard let configuration = try store.load() else {
        return compile(.empty, configState: .fresh)
      }
      return compile(configuration, configState: .ok)
    } catch let corruption as ConfigurationCorruption {
      return preserveCurrentState(
        configState: AgentConfigurationState(corruption: corruption),
        error: corruption.localizedDescription
      )
    } catch {
      return preserveCurrentState(configState: .unavailable, error: error.localizedDescription)
    }
  }

  public func statusFields() -> (
    configState: AgentConfigurationState,
    bindingCount: Int,
    lastReloadError: String?,
    unresolvedBundleIDs: [String]
  ) {
    lock.withLock {
      (
        currentConfigState,
        currentBindingCount,
        currentLastReloadError,
        currentUnresolvedBundleIDs
      )
    }
  }

  private func compile(
    _ configuration: SummondConfiguration,
    configState: AgentConfigurationState
  ) -> AgentConfigurationReloadResult {
    do {
      let compiled = try BindingCompiler.compile(
        configuration.bindings,
        appResolver: appResolver
      )
      let unresolvedBundleIDs = compiled.unresolvedBundleIDs
      lock.withLock {
        currentBindingCount = compiled.snapshot.count
        currentConfigState = configState
        currentVerboseLogging = configuration.verboseLogging
        currentLastReloadError = nil
        currentUnresolvedBundleIDs = unresolvedBundleIDs
      }
      return AgentConfigurationReloadResult(
        snapshotToInstall: compiled.snapshot,
        verboseLogging: configuration.verboseLogging,
        lastReloadError: nil
      )
    } catch {
      return preserveCurrentState(configState: .invalid, error: error.localizedDescription)
    }
  }

  private func preserveCurrentState(
    configState: AgentConfigurationState,
    error: String
  ) -> AgentConfigurationReloadResult {
    let verboseLogging = lock.withLock {
      currentConfigState = configState
      currentLastReloadError = error
      return currentVerboseLogging
    }
    return AgentConfigurationReloadResult(
      snapshotToInstall: nil,
      verboseLogging: verboseLogging,
      lastReloadError: error
    )
  }
}
