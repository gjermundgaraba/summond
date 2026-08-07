import AppKit
import CoreGraphics
import Foundation
import Observation
import SummondCore

@MainActor
@Observable
final class SummondModel {
  enum LoadState: Equatable {
    case fresh
    case loaded
    case corrupt(ConfigurationCorruption)
    case unavailable(String)
  }

  private let storage: any ConfigurationStore
  private let agentClient: any AgentClientProtocol
  private let agentService: any LoginItemServiceManaging
  private let statusItemService: any LoginItemServiceManaging
  private let appCatalog: any AppDisplayResolving
  private let savedDataRemover: any SavedDataRemoving
  private let repairSleep: @Sendable (Duration) async -> Void
  private let isStatusItemRunning: @Sendable () -> Bool

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
  private(set) var isPreparingToUninstall = false

  private(set) var configurationError: String?
  private(set) var reloadError: String?
  private(set) var serviceError: String?
  private(set) var permissionError: String?
  private(set) var statusItemError: String?
  private(set) var uninstallPreparationError: String?

  @ObservationIgnored
  private var agentRequestSequence = 0

  init(
    storage: any ConfigurationStore,
    agentClient: any AgentClientProtocol = AgentClient(),
    agentService: any LoginItemServiceManaging = LoginItemService(
      agentPlistName: SummondBundleIdentifiers.agentPlistName
    ),
    statusItemService: any LoginItemServiceManaging = LoginItemService(
      loginItemIdentifier: SummondBundleIdentifiers.statusItem
    ),
    appCatalog: (any AppDisplayResolving)? = nil,
    savedDataRemover: any SavedDataRemoving = LocalSavedDataRemover(),
    repairSleep: @escaping @Sendable (Duration) async -> Void = {
      try? await Task.sleep(for: $0)
    },
    isStatusItemRunning: @escaping @Sendable () -> Bool = {
      !NSRunningApplication.runningApplications(
        withBundleIdentifier: SummondBundleIdentifiers.statusItem
      ).isEmpty
    }
  ) {
    self.storage = storage
    self.agentClient = agentClient
    self.agentService = agentService
    self.statusItemService = statusItemService
    self.appCatalog = appCatalog ?? InstalledAppCatalog()
    self.savedDataRemover = savedDataRemover
    self.repairSleep = repairSleep
    self.isStatusItemRunning = isStatusItemRunning
    self.serviceStatus = agentService.status
    self.statusItemStatus = statusItemService.status

    do {
      if let configuration = try storage.load() {
        self.configuration = configuration
        self.loadState = .loaded
      } else {
        self.configuration = .empty
        self.loadState = .fresh
      }
    } catch let corruption as ConfigurationCorruption {
      self.configuration = .empty
      self.loadState = .corrupt(corruption)
    } catch {
      self.configuration = .empty
      self.loadState = .unavailable(error.localizedDescription)
    }
  }

  var health: SystemHealth {
    if case .unavailable(let message) = loadState {
      return .degraded(.configurationUnavailable(details: message))
    }
    if case .corrupt(let corruption) = loadState {
      return .degraded(.configurationCorrupt(details: corruption.localizedDescription))
    }
    if let configurationError {
      return .degraded(.configurationUnavailable(details: configurationError))
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

  var canRecoverCorruptConfiguration: Bool {
    if case .corrupt = loadState { return true }
    return false
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
  func recoverCorruptConfiguration() async -> ConfigurationMutationResult {
    guard canRecoverCorruptConfiguration else {
      return .failed("The configuration does not need to be recovered.")
    }
    guard !isSaving else {
      return .failed("Another change is still being saved.")
    }
    isSaving = true
    defer { isSaving = false }

    do {
      try storage.replace(with: configuration)
    } catch {
      configurationError = error.localizedDescription
      return .failed(error.localizedDescription)
    }
    return await acceptPersistedConfiguration(configuration)
  }

  func refresh() async {
    let sequence = beginAgentRequest()
    refreshRegistrationStatuses()
    let shouldReload = retryUnavailableConfigurationLoad() || reloadError != nil

    do {
      let status =
        if shouldReload {
          try await agentClient.reloadConfiguration()
        } else {
          try await agentClient.status()
        }
      guard isCurrentAgentRequest(sequence) else {
        return
      }
      agentStatus = status
      reloadError = nil
      permissionError = nil
    } catch {
      // A task tied to a disappearing view is routinely cancelled. Its final
      // XPC error must not overwrite the last verified status.
      guard isCurrentAgentRequest(sequence) else {
        return
      }
      agentStatus = nil
      if shouldReload {
        reloadError = error.localizedDescription
      }
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
      permissionError = nil
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

  func restartService() async {
    await runServiceOperation {
      try await agentService.unregister()
      try await agentService.register()
    }
  }

  func start() async {
    await repairStaleRegistrations()
    await refresh()
  }

  /// SMAppService pins the registered binary's code requirement, so after an
  /// app update launchd refuses to spawn the stale registration (EX_CONFIG)
  /// until the owning app re-registers. Calling `register()` alone does not
  /// refresh the pinned requirement; only unregister-then-register does. Run
  /// that repair only for items that are enabled yet not actually running, so
  /// healthy services are never restarted and disabled items stay disabled.
  private func repairStaleRegistrations() async {
    if statusItemService.status == .enabled, !isStatusItemRunning() {
      isStatusItemBusy = true
      defer { isStatusItemBusy = false }
      do {
        try await repairRegistration(of: statusItemService)
        statusItemError = nil
      } catch {
        statusItemError = error.localizedDescription
      }
      statusItemStatus = statusItemService.status
    }

    guard agentService.status == .enabled else {
      return
    }
    isServiceBusy = true
    defer { isServiceBusy = false }
    if (try? await agentClient.status()) != nil {
      return
    }
    do {
      try await repairRegistration(of: agentService)
      serviceError = nil
    } catch {
      serviceError = error.localizedDescription
    }
    serviceStatus = agentService.status
  }

  /// Failed registers retry alone because a second unregister would discard
  /// the registration this repair restores.
  private func repairRegistration(of service: any LoginItemServiceManaging) async throws {
    try await service.unregister()
    let delays: [Duration] = [.milliseconds(500), .seconds(2), .seconds(5)]
    for (attempt, delay) in delays.enumerated() {
      await repairSleep(delay)
      do {
        try await service.register()
        return
      } catch {
        if attempt == delays.count - 1 {
          throw error
        }
      }
    }
  }

  func setStatusItemShown(_ isShown: Bool) async {
    // Settings disables the toggle during this operation. Dropping a second
    // request also protects SMAppService from overlapping register calls.
    guard !isStatusItemBusy, !isPreparingToUninstall else {
      return
    }
    isStatusItemBusy = true
    defer { isStatusItemBusy = false }

    if isShown {
      do {
        try await statusItemService.register()
        statusItemError = nil
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

  func clearUninstallPreparationError() {
    uninstallPreparationError = nil
  }

  func prepareForUninstall(deleteSavedData: Bool) async -> Bool {
    guard !isPreparingToUninstall, !isServiceBusy, !isStatusItemBusy else {
      uninstallPreparationError = "Another background operation is still in progress."
      return false
    }

    isPreparingToUninstall = true
    uninstallPreparationError = nil
    defer {
      isPreparingToUninstall = false
      refreshRegistrationStatuses()
    }

    if agentService.status.needsUnregisterForUninstall {
      do {
        try await agentService.unregister()
        serviceError = nil
        agentStatus = nil
      } catch {
        serviceError = error.localizedDescription
        uninstallPreparationError =
          "The background service could not be unregistered: \(error.localizedDescription)"
        return false
      }
    }

    if statusItemService.status.needsUnregisterForUninstall {
      do {
        try await statusItemService.unregister()
        statusItemError = nil
      } catch {
        statusItemError = error.localizedDescription
        uninstallPreparationError =
          "The menu bar item could not be unregistered: \(error.localizedDescription)"
        return false
      }
    }
    terminateStatusItem()

    if deleteSavedData {
      do {
        try savedDataRemover.removeAllSavedData()
      } catch {
        uninstallPreparationError =
          "Saved shortcuts and settings could not be deleted: \(error.localizedDescription)"
        return false
      }
    }
    return true
  }

  func requestAccessibilitySetup() async {
    do {
      try await agentClient.requestAccessibilityPrompt()
      permissionError = nil
    } catch {
      permissionError = error.localizedDescription
    }
  }

  func openLoginItemsSettings() {
    agentService.openSystemSettingsLoginItems()
  }

  func openAccessibilitySettings() {
    openSystemSettings(
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )
  }

  private func retryUnavailableConfigurationLoad() -> Bool {
    guard case .unavailable = loadState else {
      return false
    }

    do {
      if let configuration = try storage.load() {
        self.configuration = configuration
        loadState = .loaded
      } else {
        configuration = .empty
        loadState = .fresh
      }
      configurationError = nil
      return true
    } catch let corruption as ConfigurationCorruption {
      configuration = .empty
      loadState = .corrupt(corruption)
    } catch {
      loadState = .unavailable(error.localizedDescription)
    }
    return false
  }

  private func persist(_ next: SummondConfiguration) async -> ConfigurationMutationResult {
    if case .unavailable(let message) = loadState {
      return .failed(message)
    }
    guard !isSaving else {
      return .failed("Another change is still being saved.")
    }
    isSaving = true
    defer { isSaving = false }

    do {
      try storage.save(next)
    } catch {
      if let corruption = error as? ConfigurationCorruption {
        loadState = .corrupt(corruption)
      }
      configurationError = error.localizedDescription
      return .failed(error.localizedDescription)
    }

    return await acceptPersistedConfiguration(next)
  }

  private func acceptPersistedConfiguration(
    _ next: SummondConfiguration
  ) async -> ConfigurationMutationResult {
    configuration = next
    loadState = .loaded
    configurationError = nil

    let sequence = beginAgentRequest()
    do {
      let status = try await agentClient.reloadConfiguration()
      if isCurrentAgentRequest(sequence) {
        agentStatus = status
        reloadError = nil
        permissionError = nil
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
    guard !isServiceBusy, !isPreparingToUninstall else {
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

extension ServiceRegistrationStatus {
  fileprivate var needsUnregisterForUninstall: Bool {
    switch self {
    case .enabled, .requiresApproval:
      true
    case .notRegistered, .notFound:
      false
    }
  }
}
