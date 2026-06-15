import Foundation

public enum AgentConfigurationState: String, Codable, Equatable, Sendable {
  case ok
  case fresh
  case corrupt
  case invalid
}

public enum EventTapFailureReason: String, Codable, Equatable, Sendable {
  case accessibilityDenied
  case inputMonitoringDenied
  case installationFailed
  case disabledByTimeout
  case disabledByUserInput
}

public struct AgentStatus: Codable, Equatable, Sendable {
  public var agentVersion: String
  public var accessibilityGranted: Bool
  public var inputMonitoringGranted: Bool
  public var tapActive: Bool
  public var tapFailureReason: EventTapFailureReason?
  public var configState: AgentConfigurationState
  public var bindingCount: Int
  public var lastReloadError: String?
  public var unresolvedBundleIDs: [String]

  public init(
    agentVersion: String,
    accessibilityGranted: Bool,
    inputMonitoringGranted: Bool,
    tapActive: Bool,
    tapFailureReason: EventTapFailureReason? = nil,
    configState: AgentConfigurationState,
    bindingCount: Int,
    lastReloadError: String?,
    unresolvedBundleIDs: [String] = []
  ) {
    self.agentVersion = agentVersion
    self.accessibilityGranted = accessibilityGranted
    self.inputMonitoringGranted = inputMonitoringGranted
    self.tapActive = tapActive
    self.tapFailureReason = tapFailureReason
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
  func requestAccessibilityPrompt()
  func requestInputMonitoringPrompt()
}
