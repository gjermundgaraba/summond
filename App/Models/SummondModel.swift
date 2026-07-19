import AppKit
import CoreGraphics
import Foundation
import Observation
import SummondCore

@MainActor
@Observable
final class SummondModel {
  enum ConfigurationStorage {
    case available(any ConfigurationStore)
    case unavailable(String)
  }

  enum LoadState: Equatable {
    case fresh
    case loaded
    case corrupt(ConfigurationCorruption)
    case unavailable(String)
  }

  private let storage: ConfigurationStorage
  private let agentClient: any AgentClientProtocol
  private let agentService: any LoginItemServiceManaging
  private let statusItemService: any LoginItemServiceManaging
  private let appCatalog: any AppDisplayResolving

  private(set) var configuration: SummondConfiguration
  private(set) var loadState: LoadState
  private(set) var serviceStatus: ServiceRegistrationStatus
  private(set) var statusItemStatus: ServiceRegistrationStatus
  private(set) var agentStatus: AgentStatus?

  private(set) var installedApplications: [AppDisplayInfo] = []
  private(set) var installedAppsLoaded = false
  private(set) var installedAppsLoading = false

  private(set) var isSaving = false
  private(set) var isReloading = false
  private(set) var isServiceBusy = false
  private(set) var isStatusItemBusy = false

  private(set) var configurationError: String?
  private(set) var reloadError: String?
  private(set) var serviceError: String?
  private(set) var statusItemError: String?

  @ObservationIgnored
  private var agentRequestSequence = 0

  init(
    storage: ConfigurationStorage,
    agentClient: any AgentClientProtocol = AgentClient(),
    agentService: any LoginItemServiceManaging = LoginItemService(
      agentPlistName: SummondBundleIdentifiers.agentPlistName
    ),
    statusItemService: any LoginItemServiceManaging = LoginItemService(
      loginItemIdentifier: SummondBundleIdentifiers.statusItem
    ),
    appCatalog: (any AppDisplayResolving)? = nil
  ) {
    self.storage = storage
    self.agentClient = agentClient
    self.agentService = agentService
    self.statusItemService = statusItemService
    self.appCatalog = appCatalog ?? InstalledAppCatalog()
    self.serviceStatus = agentService.status
    self.statusItemStatus = statusItemService.status

    switch storage {
    case .unavailable(let message):
      self.configuration = .empty
      self.loadState = .unavailable(message)
    case .available(let store):
      switch store.load() {
      case .fresh(let configuration):
        self.configuration = configuration
        self.loadState = .fresh
      case .loaded(let configuration):
        self.configuration = configuration
        self.loadState = .loaded
      case .corrupt(let corruption):
        self.configuration = .empty
        self.loadState = .corrupt(corruption)
      }
    }
  }

  var health: SystemHealth {
    if case .unavailable(let message) = loadState {
      return .degraded(.configurationUnavailable(details: message))
    }
    if let configurationError {
      return .degraded(.configurationUnavailable(details: configurationError))
    }
    if case .corrupt(let corruption) = loadState {
      return .degraded(.configurationCorrupt(details: corruption.localizedDescription))
    }
    if let reloadError {
      return .degraded(.reloadFailed(details: reloadError))
    }
    return SystemHealth.evaluate(serviceStatus: serviceStatus, agentStatus: agentStatus)
  }

  /// A service awaiting approval represents an enabled user preference even
  /// though macOS has not allowed it to launch yet.
  var isStatusItemShown: Bool {
    statusItemStatus == .enabled || statusItemStatus == .requiresApproval
  }

  func displayInfo(for bundleID: String) -> AppDisplayInfo {
    appCatalog.displayInfo(for: bundleID)
  }

  func identity(forApplicationURL url: URL) -> AppIdentity? {
    appCatalog.identity(forApplicationURL: url)
  }

  func loadInstalledApplicationsIfNeeded() async {
    guard !installedAppsLoaded, !installedAppsLoading else {
      return
    }

    installedAppsLoading = true
    defer { installedAppsLoading = false }
    installedApplications = await appCatalog.installedApplications()
    installedAppsLoaded = true
  }

  func recordShortcut(keyCode: CGKeyCode, flags: CGEventFlags) -> ShortcutRecordResult {
    guard let keyName = KeyCode.name(for: keyCode) else {
      return .unsupportedKey
    }
    let relevantFlags = flags.intersection(KeyCode.relevantModifiersMask)
    return .recorded(
      ShortcutDraft(
        key: keyName,
        mods: KeyCode.modifierNames(for: relevantFlags)
      ))
  }

  func validationIssues(for draft: ShortcutEditorDraft) -> [ShortcutDraftIssue] {
    var issues: [ShortcutDraftIssue] = []
    var compiledShortcut: CompiledShortcut?

    if let shortcut = draft.shortcut.shortcut {
      do {
        compiledShortcut = try BindingCompiler.compileShortcut(shortcut)
      } catch {
        switch error {
        case .unknownKey(let key):
          issues.append(.unsupportedKey(key))
        case .unknownModifiers(let modifiers):
          issues.append(.unsupportedModifiers(modifiers))
        }
      }

      if compiledShortcut != nil,
        KeyCode.producesLiteralText(shortcut.key),
        !shortcutHasSafeModifier(shortcut)
      {
        issues.append(.unsafePrintableShortcut)
      }

      if let compiledShortcut,
        let conflict = conflictingShortcut(
          compiledShortcut,
          excluding: draft.editingID
        )
      {
        issues.append(
          .duplicate(
            existing: ShortcutSummary(
              shortcut: conflict.shortcut,
              applicationName: displayInfo(for: conflict.target.bundleID).displayName
            )))
      }
    } else {
      issues.append(.missingShortcut)
    }

    if draft.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      issues.append(.missingApplication)
    }

    return issues
  }

  func saveShortcut(_ draft: ShortcutEditorDraft) async -> ConfigurationMutationResult {
    let issues = validationIssues(for: draft)
    guard issues.isEmpty else {
      return .invalid(issues)
    }

    guard let shortcut = draft.shortcut.shortcut else {
      return .invalid([.missingShortcut])
    }
    guard let target = try? AppTarget(bundleID: draft.bundleID, mode: draft.mode) else {
      return .invalid([.missingApplication])
    }

    var next = configuration
    let binding = StoredBinding(
      id: draft.editingID ?? UUID(),
      shortcut: shortcut,
      target: target
    )

    switch draft.purpose {
    case .add:
      next.bindings.append(binding)
    case .edit(let id):
      guard let index = next.bindings.firstIndex(where: { $0.id == id }) else {
        return .failed("This shortcut no longer exists. Refresh and try again.")
      }
      next.bindings[index] = binding
    }

    return await persist(next)
  }

  @discardableResult
  func deleteShortcut(id: UUID) async -> ConfigurationMutationResult {
    guard configuration.bindings.contains(where: { $0.id == id }) else {
      return .failed("This shortcut no longer exists.")
    }
    var next = configuration
    next.bindings.removeAll { $0.id == id }
    return await persist(next)
  }

  @discardableResult
  func setVerboseLogging(_ isEnabled: Bool) async -> ConfigurationMutationResult {
    guard configuration.verboseLogging != isEnabled else {
      return .saved
    }
    var next = configuration
    next.verboseLogging = isEnabled
    return await persist(next)
  }

  @discardableResult
  func resetCorruptConfiguration() async -> ConfigurationMutationResult {
    await persist(.empty)
  }

  func refresh() async {
    let sequence = beginAgentRequest()
    refreshRegistrationStatuses()

    do {
      let status = try await agentClient.status()
      guard isCurrentAgentRequest(sequence) else {
        return
      }
      agentStatus = status
      reloadError = nil
    } catch {
      // A task tied to a disappearing view is routinely cancelled. Its final
      // XPC error must not overwrite the last verified status.
      guard isCurrentAgentRequest(sequence) else {
        return
      }
      agentStatus = nil
    }
  }

  func retryReload() async {
    guard !isReloading else {
      return
    }
    isReloading = true
    defer { isReloading = false }
    let sequence = beginAgentRequest()

    do {
      let status = try await agentClient.reloadConfiguration()
      guard isCurrentAgentRequest(sequence) else { return }
      agentStatus = status
      reloadError = nil
    } catch {
      guard isCurrentAgentRequest(sequence) else { return }
      reloadError = error.localizedDescription
    }
    refreshRegistrationStatuses()
  }

  func enableService() async {
    await runServiceOperation {
      try await agentService.register()
    }
  }

  func disableService() async {
    await runServiceOperation {
      try await agentService.unregister()
    }
  }

  func restartService() async {
    await runServiceOperation {
      try await agentService.unregister()
      try await agentService.register()
    }
  }

  func setStatusItemShown(_ isShown: Bool) async {
    // Settings disables the toggle during this operation. Dropping a second
    // request also protects SMAppService from overlapping register calls.
    guard !isStatusItemBusy else {
      return
    }
    isStatusItemBusy = true
    defer { isStatusItemBusy = false }

    if isShown {
      do {
        try await statusItemService.register()
        statusItemError = nil
        launchStatusItem()
      } catch {
        statusItemError = error.localizedDescription
      }
    } else {
      do {
        try await statusItemService.unregister()
        statusItemError = nil
        terminateStatusItem()
      } catch {
        statusItemError = error.localizedDescription
      }
    }
    statusItemStatus = statusItemService.status
  }

  func requestAccessibilitySetup() {
    agentClient.requestAccessibilityPrompt()
  }

  func requestInputMonitoringSetup() {
    agentClient.requestInputMonitoringPrompt()
  }

  func openLoginItemsSettings() {
    agentService.openSystemSettingsLoginItems()
  }

  func openAccessibilitySettings() {
    openSystemSettings(
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )
  }

  func openInputMonitoringSettings() {
    openSystemSettings(
      "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    )
  }

  private func persist(_ next: SummondConfiguration) async -> ConfigurationMutationResult {
    guard !isSaving else {
      return .failed("Another change is still being saved.")
    }
    isSaving = true
    defer { isSaving = false }

    switch storage {
    case .unavailable(let message):
      return .failed(message)
    case .available(let store):
      do {
        try store.save(next)
      } catch {
        configurationError = error.localizedDescription
        return .failed(error.localizedDescription)
      }
    }

    configuration = next
    loadState = .loaded
    configurationError = nil

    let sequence = beginAgentRequest()
    do {
      let status = try await agentClient.reloadConfiguration()
      if isCurrentAgentRequest(sequence) {
        agentStatus = status
        reloadError = nil
      }
      return .saved
    } catch {
      let message = error.localizedDescription
      if isCurrentAgentRequest(sequence) {
        reloadError = message
      }
      return .savedButReloadFailed(message)
    }
  }

  private func conflictingShortcut(
    _ shortcut: CompiledShortcut,
    excluding excludedID: UUID?
  ) -> StoredBinding? {
    configuration.bindings.first { binding in
      guard binding.id != excludedID else {
        return false
      }
      return (try? BindingCompiler.compileShortcut(binding.shortcut)) == shortcut
    }
  }

  private func shortcutHasSafeModifier(_ shortcut: Shortcut) -> Bool {
    shortcut.mods.contains { modifier in
      switch modifier.lowercased() {
      case "cmd", "command", "alt", "opt", "option", "ctrl", "control":
        true
      default:
        false
      }
    }
  }

  private func refreshRegistrationStatuses() {
    serviceStatus = agentService.status
    statusItemStatus = statusItemService.status
  }

  private func beginAgentRequest() -> Int {
    agentRequestSequence &+= 1
    return agentRequestSequence
  }

  private func isCurrentAgentRequest(_ sequence: Int) -> Bool {
    sequence == agentRequestSequence && !Task.isCancelled
  }

  private func runServiceOperation(_ operation: () async throws -> Void) async {
    guard !isServiceBusy else {
      return
    }
    isServiceBusy = true
    defer { isServiceBusy = false }

    do {
      try await operation()
      serviceError = nil
    } catch {
      serviceError = error.localizedDescription
    }
    await refresh()
  }

  private func launchStatusItem() {
    #if DEBUG
      if UITestHarness.isActive { return }
    #endif
    let statusItemURL = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Library/LoginItems/SummondStatus.app")
    guard FileManager.default.fileExists(atPath: statusItemURL.path) else {
      statusItemError = "SummondStatus.app was not found in this app bundle."
      return
    }

    let launchConfiguration = NSWorkspace.OpenConfiguration()
    NSWorkspace.shared.openApplication(at: statusItemURL, configuration: launchConfiguration) {
      [weak self] _, error in
      guard let error else {
        return
      }
      Task { @MainActor in
        self?.statusItemError = error.localizedDescription
      }
    }
  }

  private func terminateStatusItem() {
    #if DEBUG
      if UITestHarness.isActive { return }
    #endif
    for application in NSRunningApplication.runningApplications(
      withBundleIdentifier: SummondBundleIdentifiers.statusItem
    ) {
      application.terminate()
    }
  }

  private func openSystemSettings(_ address: String) {
    guard let url = URL(string: address) else {
      return
    }
    NSWorkspace.shared.open(url)
  }
}
