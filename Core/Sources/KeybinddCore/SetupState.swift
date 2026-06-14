import Foundation

public enum OnboardingStep: Int, Codable, Equatable, Sendable, CaseIterable {
  case welcome
  case backgroundService
  case accessibility
  case inputMonitoring
  case done
}

public struct SetupState: Equatable, Sendable {
  public var serviceStatus: ServiceRegistrationStatus
  public var agentReachable: Bool
  public var accessibilityGranted: Bool
  public var inputMonitoringGranted: Bool

  public init(
    serviceStatus: ServiceRegistrationStatus,
    agentReachable: Bool = true,
    accessibilityGranted: Bool,
    inputMonitoringGranted: Bool
  ) {
    self.serviceStatus = serviceStatus
    self.agentReachable = agentReachable
    self.accessibilityGranted = accessibilityGranted
    self.inputMonitoringGranted = inputMonitoringGranted
  }

  public init(serviceStatus: ServiceRegistrationStatus, agentStatus: AgentStatus?) {
    self.init(
      serviceStatus: serviceStatus,
      agentReachable: agentStatus != nil,
      accessibilityGranted: agentStatus?.accessibilityGranted == true,
      inputMonitoringGranted: agentStatus?.inputMonitoringGranted == true
    )
  }

  public var serviceEnabled: Bool {
    serviceStatus == .enabled
  }

  public var serviceReady: Bool {
    serviceEnabled && agentReachable
  }

  public var hardRequirementsSatisfied: Bool {
    serviceReady && accessibilityGranted && inputMonitoringGranted
  }

  public var firstUnmetOnboardingStep: OnboardingStep? {
    guard serviceReady else {
      return .backgroundService
    }
    guard accessibilityGranted else {
      return .accessibility
    }
    guard inputMonitoringGranted else {
      return .inputMonitoring
    }
    return nil
  }

  public func resolvedStep(from currentStep: OnboardingStep) -> OnboardingStep {
    guard currentStep != .welcome else {
      return .welcome
    }
    return firstUnmetOnboardingStep ?? .done
  }
}
