import Foundation

public enum ServiceRegistrationStatus: String, Codable, Equatable, Sendable {
  case enabled
  case requiresApproval
  case notRegistered
  case notFound
}
