import Foundation

public enum AgentConfigurationState: String, Codable, Equatable, Sendable {
  case ok
  case fresh
  case unavailable
  case corrupt
  case invalid

  public init(corruption: ConfigurationCorruption) {
    switch corruption {
    case .undecodable:
      self = .corrupt
    case .invalid:
      self = .invalid
    }
  }
}

public struct AgentStatus: Codable, Equatable, Sendable {
  public var agentVersion: String
  /// Accessibility gates the New Window and Move open modes (Dock menu and
  /// Space queries), not shortcut delivery -- hot keys need no permission.
  public var accessibilityGranted: Bool
  /// Whether any active binding uses an open mode that needs Accessibility.
  /// Health treats a missing permission as setup work only when this is true.
  public var accessibilityRequired: Bool
  public var shortcutsActive: Bool
  /// Shortcut descriptions whose system hot-key registration failed. Degraded
  /// state like `unresolvedBundleIDs`: the remaining bindings stay active.
  public var failedShortcuts: [String]
  public var configState: AgentConfigurationState
  public var bindingCount: Int
  public var lastReloadError: String?
  public var unresolvedBundleIDs: [String]

  public init(
    agentVersion: String,
    accessibilityGranted: Bool,
    accessibilityRequired: Bool,
    shortcutsActive: Bool,
    failedShortcuts: [String] = [],
    configState: AgentConfigurationState,
    bindingCount: Int,
    lastReloadError: String?,
    unresolvedBundleIDs: [String] = []
  ) {
    self.agentVersion = agentVersion
    self.accessibilityGranted = accessibilityGranted
    self.accessibilityRequired = accessibilityRequired
    self.shortcutsActive = shortcutsActive
    self.failedShortcuts = failedShortcuts
    self.configState = configState
    self.bindingCount = bindingCount
    self.lastReloadError = lastReloadError
    self.unresolvedBundleIDs = unresolvedBundleIDs
  }

}

public enum AgentStatusCodec {
  public static func encode(_ status: AgentStatus) -> Data {
    // AgentStatus is a fixed schema of String/Bool/Int/[String] values, so
    // encoding cannot fail; trapping beats returning empty Data the client would
    // mis-decode as a corrupt reply.
    try! JSONEncoder().encode(status)
  }

  public static func decode(_ data: Data) throws -> AgentStatus {
    try JSONDecoder().decode(AgentStatus.self, from: data)
  }
}

@objc public protocol SummondAgentXPC {
  func status(reply: @escaping (Data) -> Void)
  func reloadConfiguration(reply: @escaping (Data) -> Void)
  func requestAccessibilityPrompt(reply: @escaping (Data) -> Void)
}
