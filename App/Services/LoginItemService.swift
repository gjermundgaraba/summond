import Foundation
@preconcurrency import ServiceManagement
import SummondCore

protocol LoginItemServiceManaging: Sendable {
  var status: ServiceRegistrationStatus { get }
  func register() async throws
  func unregister() async throws
  func openSystemSettingsLoginItems()
}

struct LoginItemService: LoginItemServiceManaging, Sendable {
  private enum Descriptor: Sendable {
    case agent(plistName: String)
    case loginItem(identifier: String)

    var service: SMAppService {
      switch self {
      case .agent(let plistName):
        SMAppService.agent(plistName: plistName)
      case .loginItem(let identifier):
        SMAppService.loginItem(identifier: identifier)
      }
    }
  }

  private let descriptor: Descriptor

  init(agentPlistName plistName: String) {
    descriptor = .agent(plistName: plistName)
  }

  init(loginItemIdentifier identifier: String) {
    descriptor = .loginItem(identifier: identifier)
  }

  var status: ServiceRegistrationStatus {
    switch descriptor.service.status {
    case .enabled:
      .enabled
    case .requiresApproval:
      .requiresApproval
    case .notRegistered:
      .notRegistered
    case .notFound:
      .notFound
    @unknown default:
      .notFound
    }
  }

  func register() async throws {
    // Registration can block while launchd processes the request. Rebuild the
    // handle from its Sendable descriptor off the main actor instead of sending
    // SMAppService itself across the concurrency boundary.
    let descriptor = descriptor
    try await Task.detached(priority: .userInitiated) {
      try descriptor.service.register()
    }.value
  }

  func unregister() async throws {
    let descriptor = descriptor
    try await Task.detached(priority: .userInitiated) {
      try await descriptor.service.unregister()
    }.value
  }

  func openSystemSettingsLoginItems() {
    SMAppService.openSystemSettingsLoginItems()
  }
}
