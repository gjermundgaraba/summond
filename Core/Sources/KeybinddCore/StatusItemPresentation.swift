import Foundation

public struct StatusItemPresentation: Equatable, Sendable {
  public let statusLine: String
  public let showsWarningBadge: Bool
  public let canReload: Bool

  public init(
    statusLine: String,
    showsWarningBadge: Bool,
    canReload: Bool
  ) {
    self.statusLine = statusLine
    self.showsWarningBadge = showsWarningBadge
    self.canReload = canReload
  }
}

public enum StatusItemPresentationMapper {
  /// The menu bar status item lives in its own process and can only observe the
  /// agent through XPC; it has no access to the agent's `SMAppService`
  /// registration. Presentation is therefore derived purely from agent
  /// reachability and the status it reports — a nil `agentStatus` means the
  /// agent did not answer, not that the service is unregistered.
  public static func presentation(agentStatus: AgentStatus?) -> StatusItemPresentation {
    guard let agentStatus else {
      return StatusItemPresentation(
        statusLine: "Keybindd isn't responding",
        showsWarningBadge: true,
        canReload: false
      )
    }

    let state = agentStateLine(for: agentStatus)
    return StatusItemPresentation(
      statusLine: state.line,
      showsWarningBadge: state.isWarning,
      canReload: true
    )
  }

  private static func agentStateLine(for status: AgentStatus) -> (line: String, isWarning: Bool) {
    if !status.accessibilityGranted {
      return ("Needs Accessibility permission", true)
    }

    if !status.inputMonitoringGranted {
      return ("Needs Input Monitoring", true)
    }

    switch status.configState {
    case .corrupt, .invalid:
      return ("Configuration problem", true)
    case .ok, .fresh:
      break
    }

    if !status.unresolvedBundleIDs.isEmpty {
      let count = status.unresolvedBundleIDs.count
      return ("\(count) \(count == 1 ? "app" : "apps") not installed", true)
    }

    if let tapFailureReason = status.tapFailureReason {
      return (tapFailureLine(for: tapFailureReason), true)
    }

    if !status.tapActive {
      return ("Event tap inactive", true)
    }

    let shortcutWord = status.bindingCount == 1 ? "shortcut" : "shortcuts"
    return ("Active — \(status.bindingCount) \(shortcutWord)", false)
  }

  private static func tapFailureLine(for reason: EventTapFailureReason) -> String {
    switch reason {
    case .accessibilityDenied:
      "Needs Accessibility permission"
    case .inputMonitoringDenied:
      "Needs Input Monitoring"
    case .installationFailed:
      "Event tap unavailable"
    case .disabledByTimeout:
      "Event tap timed out"
    case .disabledByUserInput:
      "Event tap disabled"
    }
  }
}
