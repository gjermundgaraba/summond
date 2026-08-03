import Foundation

public struct AgentConfigurationReloadResult: Sendable {
  public let snapshotToInstall: BindingSnapshot?
  public let configState: AgentConfigurationState
  public let bindingCount: Int
  public let verboseLogging: Bool
  public let lastReloadError: String?
  public let unresolvedBundleIDs: [String]

  public init(
    snapshotToInstall: BindingSnapshot?,
    configState: AgentConfigurationState,
    bindingCount: Int,
    verboseLogging: Bool,
    lastReloadError: String?,
    unresolvedBundleIDs: [String] = []
  ) {
    self.snapshotToInstall = snapshotToInstall
    self.configState = configState
    self.bindingCount = bindingCount
    self.verboseLogging = verboseLogging
    self.lastReloadError = lastReloadError
    self.unresolvedBundleIDs = unresolvedBundleIDs
  }
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
    switch store.load() {
    case .fresh(let configuration):
      return compile(configuration, configState: .fresh)
    case .loaded(let configuration):
      return compile(configuration, configState: .ok)
    case .corrupt(let corruption):
      return preserveCurrentState(configState: .corrupt, error: corruption.localizedDescription)
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
        configState: configState,
        bindingCount: compiled.snapshot.count,
        verboseLogging: configuration.verboseLogging,
        lastReloadError: nil,
        unresolvedBundleIDs: unresolvedBundleIDs
      )
    } catch {
      return preserveCurrentState(configState: .invalid, error: error.localizedDescription)
    }
  }

  private func preserveCurrentState(
    configState: AgentConfigurationState,
    error: String
  ) -> AgentConfigurationReloadResult {
    let fields = lock.withLock {
      currentConfigState = configState
      currentLastReloadError = error
      return (
        bindingCount: currentBindingCount,
        verboseLogging: currentVerboseLogging,
        unresolvedBundleIDs: currentUnresolvedBundleIDs
      )
    }
    return AgentConfigurationReloadResult(
      snapshotToInstall: nil,
      configState: configState,
      bindingCount: fields.bindingCount,
      verboseLogging: fields.verboseLogging,
      lastReloadError: error,
      unresolvedBundleIDs: fields.unresolvedBundleIDs
    )
  }
}
