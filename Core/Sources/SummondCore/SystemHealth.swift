/// A user action required before Summond can become operational.
public enum SetupRequirement: Equatable, Sendable {
  case backgroundServiceApprovalRequired
  case backgroundServiceNotRegistered
  case backgroundServiceNotFound
  case accessibilityPermission
  case inputMonitoringPermission
}

/// A runtime problem that prevents Summond from operating normally.
///
/// Associated values carry diagnostic data only. User-facing copy belongs to
/// the process presenting the issue.
public enum SystemIssue: Equatable, Sendable {
  case agentUnavailable
  case configurationUnavailable(details: String)
  case configurationCorrupt(details: String?)
  case configurationInvalid(details: String?)
  case reloadFailed(details: String)
  case unresolvedApplications(bundleIDs: [String])
  case eventTapFailure(EventTapFailureReason)
  case eventTapInactive
}

/// The canonical interpretation of service and agent runtime state.
public enum SystemHealth: Equatable, Sendable {
  case ready(activeShortcuts: Int)
  case setupRequired(SetupRequirement)
  case degraded(SystemIssue)

  /// Evaluates health in the main app, where service registration is visible.
  public static func evaluate(
    serviceStatus: ServiceRegistrationStatus,
    agentStatus: AgentStatus?
  ) -> SystemHealth {
    switch serviceStatus {
    case .requiresApproval:
      return .setupRequired(.backgroundServiceApprovalRequired)
    case .notRegistered:
      return .setupRequired(.backgroundServiceNotRegistered)
    case .notFound:
      return .setupRequired(.backgroundServiceNotFound)
    case .enabled:
      return evaluate(agentStatus: agentStatus)
    }
  }

  /// Evaluates health in the status process, which can observe only the agent.
  public static func evaluate(agentStatus: AgentStatus?) -> SystemHealth {
    guard let agentStatus else {
      return .degraded(.agentUnavailable)
    }

    guard agentStatus.accessibilityGranted else {
      return .setupRequired(.accessibilityPermission)
    }

    guard agentStatus.inputMonitoringGranted else {
      return .setupRequired(.inputMonitoringPermission)
    }

    switch agentStatus.configState {
    case .corrupt:
      return .degraded(.configurationCorrupt(details: agentStatus.lastReloadError))
    case .invalid:
      return .degraded(.configurationInvalid(details: agentStatus.lastReloadError))
    case .ok, .fresh:
      break
    }

    guard agentStatus.unresolvedBundleIDs.isEmpty else {
      return .degraded(
        .unresolvedApplications(bundleIDs: agentStatus.unresolvedBundleIDs)
      )
    }

    if let failure = agentStatus.tapFailureReason {
      return .degraded(.eventTapFailure(failure))
    }

    guard agentStatus.tapActive else {
      return .degraded(.eventTapInactive)
    }

    return .ready(activeShortcuts: agentStatus.bindingCount)
  }
}
