import Foundation

public enum ServiceRegistrationStatus: String, Codable, Equatable, Sendable {
  case enabled
  case requiresApproval
  case notRegistered
  case notFound
}

public struct ServiceRegistrationPresentation: Equatable, Sendable {
  public let title: String
  public let canRegister: Bool
  public let canUnregister: Bool
  public let needsApproval: Bool

  public init(
    title: String,
    canRegister: Bool,
    canUnregister: Bool,
    needsApproval: Bool
  ) {
    self.title = title
    self.canRegister = canRegister
    self.canUnregister = canUnregister
    self.needsApproval = needsApproval
  }
}

public enum ServiceRegistrationStatusMapper {
  public static func presentation(
    for status: ServiceRegistrationStatus
  ) -> ServiceRegistrationPresentation {
    switch status {
    case .enabled:
      ServiceRegistrationPresentation(
        title: "Enabled",
        canRegister: false,
        canUnregister: true,
        needsApproval: false
      )
    case .requiresApproval:
      ServiceRegistrationPresentation(
        title: "Requires Approval",
        canRegister: false,
        canUnregister: true,
        needsApproval: true
      )
    case .notRegistered:
      ServiceRegistrationPresentation(
        title: "Not Registered",
        canRegister: true,
        canUnregister: false,
        needsApproval: false
      )
    case .notFound:
      ServiceRegistrationPresentation(
        title: "Not Found",
        canRegister: false,
        canUnregister: false,
        needsApproval: false
      )
    }
  }
}
