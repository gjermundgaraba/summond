import AppKit
import Foundation
import KeybinddCore
import Observation
@preconcurrency import ServiceManagement

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
    self.descriptor = .agent(plistName: plistName)
  }

  init(loginItemIdentifier identifier: String) {
    self.descriptor = .loginItem(identifier: identifier)
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
    // SMAppService.register() is synchronous and can block while launchd
    // processes the registration, so run it off the main actor to keep the UI
    // responsive. The descriptor is a Sendable value, so the service handle is
    // rebuilt inside the task rather than captured across the boundary.
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

@MainActor
@Observable
final class ServiceManager {
  private(set) var serviceStatus: ServiceRegistrationStatus = .notRegistered
  private(set) var statusItemStatus: ServiceRegistrationStatus = .notRegistered
  private(set) var agentStatus: AgentStatus?
  private(set) var lastRegistrationError: String?
  private(set) var isServiceBusy = false
  private(set) var isStatusItemBusy = false
  var lastError: String?
  var lastStatusItemError: String?
  var setupRequestID = 0

  private let agentService: any LoginItemServiceManaging
  private let statusItemService: any LoginItemServiceManaging
  private let agentClient: any AgentClientProtocol

  init(
    agentService: any LoginItemServiceManaging = LoginItemService(
      agentPlistName: "net.garaba.keybindd.agent.plist"
    ),
    statusItemService: any LoginItemServiceManaging = LoginItemService(
      loginItemIdentifier: KeybinddBundleIdentifiers.statusItem
    ),
    agentClient: any AgentClientProtocol = AgentClient()
  ) {
    self.agentService = agentService
    self.statusItemService = statusItemService
    self.agentClient = agentClient
    refreshServiceStatus()
    refreshStatusItemStatus()
  }

  var servicePresentation: ServiceRegistrationPresentation {
    ServiceRegistrationStatusMapper.presentation(for: serviceStatus)
  }

  var statusItemPresentation: ServiceRegistrationPresentation {
    ServiceRegistrationStatusMapper.presentation(for: statusItemStatus)
  }

  var isStatusItemShown: Bool {
    statusItemStatus == .enabled || statusItemStatus == .requiresApproval
  }

  var setupState: SetupState {
    SetupState(serviceStatus: serviceStatus, agentStatus: agentStatus)
  }

  var needsSetup: Bool {
    !setupState.hardRequirementsSatisfied
  }

  func refresh() async {
    refreshServiceStatus()
    refreshStatusItemStatus()
    do {
      agentStatus = try await agentClient.status()
      lastError = nil
    } catch {
      agentStatus = nil
      lastError = error.localizedDescription
    }
  }

  func reloadAgentConfiguration() async {
    do {
      agentStatus = try await agentClient.reloadConfiguration()
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
    refreshServiceStatus()
  }

  func register() async {
    await runAgentServiceOperation {
      try await agentService.register()
    }
  }

  func unregister() async {
    await runAgentServiceOperation {
      try await agentService.unregister()
    }
  }

  func restartServiceRegistration() async {
    await runAgentServiceOperation {
      try await agentService.unregister()
      try await agentService.register()
    }
  }

  func requestAccessibilityPrompt() {
    agentClient.requestAccessibilityPrompt()
  }

  func requestInputMonitoringPrompt() {
    agentClient.requestInputMonitoringPrompt()
  }

  func requestAccessibilitySetup() {
    requestAccessibilityPrompt()
    openAccessibilitySettings()
  }

  func requestInputMonitoringSetup() {
    requestInputMonitoringPrompt()
    openInputMonitoringSettings()
  }

  func acceptReloadedStatus(_ status: AgentStatus) {
    agentStatus = status
    lastError = nil
    refreshServiceStatus()
  }

  func openLoginItemsSettings() {
    agentService.openSystemSettingsLoginItems()
  }

  func requestOnboarding() {
    setupRequestID += 1
  }

  func setStatusItemShown(_ isShown: Bool) async {
    // Drop re-entrant register/unregister requests so rapid toggles cannot race
    // on the same SMAppService while the Settings toggle is disabled.
    guard !isStatusItemBusy else {
      return
    }
    isStatusItemBusy = true
    defer { isStatusItemBusy = false }

    if isShown {
      await registerStatusItem()
    } else {
      await unregisterStatusItem()
    }
  }

  func openAccessibilitySettings() {
    let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )
    if let url {
      NSWorkspace.shared.open(url)
    }
  }

  func openInputMonitoringSettings() {
    let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    )
    if let url {
      NSWorkspace.shared.open(url)
    }
  }

  private func refreshServiceStatus() {
    serviceStatus = agentService.status
  }

  private func refreshStatusItemStatus() {
    statusItemStatus = statusItemService.status
  }

  private func runAgentServiceOperation(_ operation: () async throws -> Void) async {
    guard !isServiceBusy else {
      return
    }
    isServiceBusy = true
    defer { isServiceBusy = false }

    do {
      try await operation()
      lastRegistrationError = nil
      lastError = nil
    } catch {
      lastRegistrationError = error.localizedDescription
      lastError = error.localizedDescription
    }
    await refresh()
  }

  private func registerStatusItem() async {
    do {
      try await statusItemService.register()
      launchStatusItem()
      lastStatusItemError = nil
    } catch {
      lastStatusItemError = error.localizedDescription
    }
    refreshStatusItemStatus()
  }

  private func unregisterStatusItem() async {
    do {
      try await statusItemService.unregister()
      terminateStatusItem()
      lastStatusItemError = nil
    } catch {
      lastStatusItemError = error.localizedDescription
    }
    refreshStatusItemStatus()
  }

  private func launchStatusItem() {
    let statusItemURL = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Library/LoginItems/KeybinddStatus.app")
    guard FileManager.default.fileExists(atPath: statusItemURL.path) else {
      lastStatusItemError = "KeybinddStatus.app was not found in this app bundle."
      return
    }

    let configuration = NSWorkspace.OpenConfiguration()
    NSWorkspace.shared.openApplication(at: statusItemURL, configuration: configuration) {
      [weak self] _, error in
      if let error {
        Task { @MainActor in
          self?.lastStatusItemError = error.localizedDescription
        }
      }
    }
  }

  private func terminateStatusItem() {
    let applications = NSRunningApplication.runningApplications(
      withBundleIdentifier: KeybinddBundleIdentifiers.statusItem
    )
    for application in applications {
      application.terminate()
    }
  }
}
