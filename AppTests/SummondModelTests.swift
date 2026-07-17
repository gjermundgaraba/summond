import Foundation
import SummondCore
import Testing

@testable import Summond

@MainActor
@Suite("Summond model")
struct SummondModelTests {
  @Test("Shortcut formatter emits macOS glyph order")
  func shortcutFormatterTokens() {
    #expect(
      ShortcutFormatter.tokens(
        for: Shortcut(key: "space", mods: ["ctrl", "cmd", "alt"])
      ) == ["⌃", "⌥", "⌘", "Space"]
    )
    #expect(ShortcutFormatter.symbols(for: Shortcut(key: "a", mods: ["cmd", "shift"])) == "⇧⌘A")
    #expect(ShortcutFormatter.tokens(for: ShortcutDraft.empty) == [])
  }

  @Test("App fuzzy match ranks subsequence matches")
  func appFuzzyMatchRanking() {
    let apps = [
      app("com.apple.TextEdit", "TextEdit"),
      app("com.apple.ActivityMonitor", "Activity Monitor"),
      app("com.apple.Terminal", "Terminal"),
    ]

    #expect(AppFuzzyMatch.score("tm", "Activity Monitor") != nil)
    #expect(AppFuzzyMatch.score("zz", "Terminal") == nil)
    #expect(AppFuzzyMatch.rank(apps, "term").first?.bundleID == "com.apple.Terminal")
    #expect(AppFuzzyMatch.rank(apps, "").map(\.bundleID) == apps.map(\.bundleID))
  }

  @Test("Printable shortcuts require a safe modifier")
  func validatesUnsafePrintableShortcuts() {
    let model = makeModel()

    #expect(model.validationIssues(for: draft(key: "space")).contains(.unsafePrintableShortcut))
    #expect(
      model.validationIssues(for: draft(key: "2", mods: ["shift"]))
        .contains(.unsafePrintableShortcut)
    )
    #expect(
      !model.validationIssues(for: draft(key: "a", mods: ["cmd"]))
        .contains(.unsafePrintableShortcut)
    )
    #expect(
      !model.validationIssues(for: draft(key: "f5"))
        .contains(.unsafePrintableShortcut)
    )
    #expect(
      !model.validationIssues(for: draft(key: "home"))
        .contains(.unsafePrintableShortcut)
    )
  }

  @Test("Adds, edits, and deletes through one persistence path")
  func addEditDelete() async throws {
    let store = MockConfigurationStore(loadResult: .fresh(.empty))
    let agent = MockAgentClient()
    let model = makeModel(store: store, agentClient: agent)

    let addResult = await model.saveShortcut(
      draft(key: "f5", mods: ["cmd", "shift"], mode: .newWindow)
    )
    #expect(addResult == .saved)
    let added = try #require(model.configuration.bindings.first)
    #expect(added.target.mode == .newWindow)

    let editResult = await model.saveShortcut(
      ShortcutEditorDraft(
        purpose: .edit(added.id),
        shortcut: ShortcutDraft(key: "f5", mods: ["cmd", "shift"]),
        bundleID: "com.apple.Safari",
        mode: .move
      ))
    #expect(editResult == .saved)
    #expect(model.configuration.bindings.first?.target.mode == .move)

    let deleteResult = await model.deleteShortcut(id: added.id)
    #expect(deleteResult == .saved)
    #expect(model.configuration.bindings.isEmpty)
    #expect(store.savedConfigurations.count == 3)
    #expect(agent.reloadCount == 3)
  }

  @Test("Duplicate validation identifies the existing shortcut")
  func duplicateValidation() throws {
    let existing = StoredBinding(
      shortcut: Shortcut(key: "f", mods: ["cmd"]),
      target: try AppTarget(bundleID: "com.apple.Safari", mode: .launch)
    )
    let store = MockConfigurationStore(
      loadResult: .loaded(SummondConfigurationV1(bindings: [existing]))
    )
    let model = makeModel(store: store)

    #expect(
      model.validationIssues(
        for: draft(key: "f", mods: ["command"], bundleID: "com.apple.Terminal")
      ).contains(
        .duplicate(
          existing: ShortcutSummary(
            shortcut: existing.shortcut,
            applicationName: "Safari"
          )))
    )
  }

  @Test("Store failure leaves configuration unchanged")
  func saveFailurePreservesConfiguration() async {
    let store = MockConfigurationStore(
      loadResult: .fresh(.empty),
      saveError: MockError.saveFailed
    )
    let model = makeModel(store: store)

    let result = await model.saveShortcut(draft(key: "a", mods: ["cmd"]))

    #expect(result == .failed(MockError.saveFailed.localizedDescription))
    #expect(model.configuration.bindings.isEmpty)
    #expect(model.configurationError == MockError.saveFailed.localizedDescription)
  }

  @Test("Reload failure keeps the saved configuration and degrades health")
  func reloadFailurePreservesSavedConfiguration() async {
    let agent = MockAgentClient(reloadError: MockError.reloadFailed)
    let model = makeModel(agentClient: agent)

    let result = await model.saveShortcut(draft(key: "a", mods: ["cmd"]))

    #expect(result == .savedButReloadFailed(MockError.reloadFailed.localizedDescription))
    #expect(model.configuration.bindings.count == 1)
    #expect(
      model.health
        == .degraded(
          .reloadFailed(details: MockError.reloadFailed.localizedDescription)
        ))

    agent.reloadError = nil
    await model.retryReload()
    #expect(model.reloadError == nil)
    #expect(model.health == .ready(activeShortcuts: 0))
  }

  @Test("Successful save immediately accepts returned agent status")
  func saveAcceptsAgentStatus() async {
    let agent = MockAgentClient(reloadStatus: healthyStatus(bindingCount: 7))
    let model = makeModel(agentClient: agent)

    _ = await model.saveShortcut(draft(key: "a", mods: ["cmd"]))

    #expect(model.agentStatus?.bindingCount == 7)
    #expect(model.health == .ready(activeShortcuts: 7))
  }

  @Test("Corrupt reset writes an empty valid configuration")
  func corruptReset() async {
    let store = MockConfigurationStore(loadResult: .corrupt(.undecodable("bad json")))
    let model = makeModel(store: store)

    guard case .corrupt = model.loadState else {
      Issue.record("Expected corrupt load state")
      return
    }
    #expect(
      model.health
        == .degraded(
          .configurationCorrupt(
            details: "Configuration data could not be decoded: bad json"
          )))

    #expect(await model.resetCorruptConfiguration() == .saved)
    #expect(store.savedConfigurations == [.empty])
    #expect(model.configuration == .empty)
    #expect(model.loadState == .loaded)
  }

  @Test("Verbose logging uses the same persistence path")
  func verboseLogging() async {
    let store = MockConfigurationStore(loadResult: .fresh(.empty))
    let model = makeModel(store: store)

    #expect(await model.setVerboseLogging(true) == .saved)
    #expect(model.configuration.verboseLogging)
    #expect(store.savedConfigurations.map(\.verboseLogging) == [true])
  }

  @Test("Unavailable durable storage blocks mutations")
  func permanentStorageError() async {
    let message = "Changes cannot be saved between launches."
    let model = SummondModel(
      storage: .unavailable(message),
      agentClient: MockAgentClient(),
      agentService: StubLoginItemService(status: .enabled),
      statusItemService: StubLoginItemService(status: .notRegistered),
      appCatalog: MockAppCatalog()
    )

    #expect(await model.setVerboseLogging(true) == .failed(message))
    #expect(!model.configuration.verboseLogging)
    #expect(model.loadState == .unavailable(message))
    #expect(model.health == .degraded(.configurationUnavailable(details: message)))
  }

  @Test("Cancelled refresh preserves the last verified status")
  func cancelledRefreshPreservesStatus() async {
    let agent = CancellableAgentClient()
    let model = makeModel(agentClient: agent)

    await model.refresh()
    #expect(model.health == .ready(activeShortcuts: 0))

    let refresh = Task { await model.refresh() }
    await agent.waitUntilSecondCallStarts()
    refresh.cancel()
    await refresh.value

    #expect(model.health == .ready(activeShortcuts: 0))
  }

  @Test("A stale refresh cannot overwrite post-save agent state")
  func staleRefreshCannotOverwriteSave() async {
    let agent = RacingAgentClient()
    let model = makeModel(agentClient: agent)

    let refresh = Task { await model.refresh() }
    await agent.waitUntilStatusStarts()

    #expect(await model.saveShortcut(draft(key: "a", mods: ["cmd"])) == .saved)
    await agent.resumeStatus()
    await refresh.value

    #expect(model.health == .ready(activeShortcuts: 7))
  }

  @Test("Concurrent status item requests do not race")
  func statusItemRequestsDoNotRace() async throws {
    let statusItem = SuspendingLoginItemService()
    let model = makeModel(statusItemService: statusItem)

    let first = Task { await model.setStatusItemShown(true) }
    let suspended = await statusItem.waitUntilRegisterSuspended()
    #expect(suspended)
    guard suspended else {
      first.cancel()
      return
    }

    await model.setStatusItemShown(false)
    #expect(statusItem.registerCalls == 1)
    #expect(statusItem.unregisterCalls == 0)

    try #require(statusItem.resumeRegister())
    await first.value
    #expect(!model.isStatusItemBusy)
  }

  @Test("Restart unregisters before registering")
  func restartService() async {
    let service = CountingLoginItemService(status: .enabled)
    let model = makeModel(agentService: service)

    await model.restartService()

    #expect(service.operations == ["unregister", "register"])
  }

  private func makeModel(
    store: MockConfigurationStore = MockConfigurationStore(loadResult: .fresh(.empty)),
    agentClient: any AgentClientProtocol = MockAgentClient(),
    agentService: any LoginItemServiceManaging = StubLoginItemService(status: .enabled),
    statusItemService: any LoginItemServiceManaging = StubLoginItemService(status: .notRegistered)
  ) -> SummondModel {
    SummondModel(
      storage: .available(store),
      agentClient: agentClient,
      agentService: agentService,
      statusItemService: statusItemService,
      appCatalog: MockAppCatalog()
    )
  }

  private func draft(
    key: String,
    mods: [String] = [],
    bundleID: String = "com.apple.Safari",
    mode: AppOpenMode = .launch
  ) -> ShortcutEditorDraft {
    ShortcutEditorDraft(
      purpose: .add,
      shortcut: ShortcutDraft(key: key, mods: mods),
      bundleID: bundleID,
      mode: mode
    )
  }

  private func app(_ bundleID: String, _ displayName: String) -> AppDisplayInfo {
    .installed(
      bundleID: bundleID,
      displayName: displayName,
      url: URL(fileURLWithPath: "/Applications/\(displayName).app")
    )
  }
}

private final class MockConfigurationStore: @unchecked Sendable, ConfigurationStore {
  var loadResult: ConfigurationLoadResult
  var saveError: Error?
  private(set) var savedConfigurations: [SummondConfigurationV1] = []

  init(loadResult: ConfigurationLoadResult, saveError: Error? = nil) {
    self.loadResult = loadResult
    self.saveError = saveError
  }

  func load() -> ConfigurationLoadResult {
    loadResult
  }

  func save(_ configuration: SummondConfigurationV1) throws {
    if let saveError {
      throw saveError
    }
    try validateConfiguration(configuration)
    savedConfigurations.append(configuration)
  }
}

private final class MockAgentClient: @unchecked Sendable, AgentClientProtocol {
  var statusValue: AgentStatus
  var reloadStatus: AgentStatus
  var statusError: Error?
  var reloadError: Error?
  private(set) var reloadCount = 0

  init(
    status: AgentStatus = healthyStatus(),
    reloadStatus: AgentStatus = healthyStatus(),
    statusError: Error? = nil,
    reloadError: Error? = nil
  ) {
    self.statusValue = status
    self.reloadStatus = reloadStatus
    self.statusError = statusError
    self.reloadError = reloadError
  }

  func status() async throws -> AgentStatus {
    if let statusError {
      throw statusError
    }
    return statusValue
  }

  func reloadConfiguration() async throws -> AgentStatus {
    reloadCount += 1
    if let reloadError {
      throw reloadError
    }
    return reloadStatus
  }

  func requestAccessibilityPrompt() {}
  func requestInputMonitoringPrompt() {}
}

private actor CancellableAgentClient: AgentClientProtocol {
  private var statusCalls = 0

  func status() async throws -> AgentStatus {
    statusCalls += 1
    if statusCalls > 1 {
      try await Task.sleep(for: .seconds(30))
    }
    return healthyStatus()
  }

  func reloadConfiguration() async throws -> AgentStatus { healthyStatus() }
  nonisolated func requestAccessibilityPrompt() {}
  nonisolated func requestInputMonitoringPrompt() {}

  func waitUntilSecondCallStarts() async {
    while statusCalls < 2 {
      await Task.yield()
    }
  }
}

private actor RacingAgentClient: AgentClientProtocol {
  private var statusContinuation: CheckedContinuation<AgentStatus, Never>?

  func status() async -> AgentStatus {
    await withCheckedContinuation { continuation in
      statusContinuation = continuation
    }
  }

  func reloadConfiguration() async -> AgentStatus {
    healthyStatus(bindingCount: 7)
  }

  nonisolated func requestAccessibilityPrompt() {}
  nonisolated func requestInputMonitoringPrompt() {}

  func waitUntilStatusStarts() async {
    while statusContinuation == nil {
      await Task.yield()
    }
  }

  func resumeStatus() {
    statusContinuation?.resume(returning: healthyStatus(bindingCount: 1))
    statusContinuation = nil
  }
}

private final class SuspendingLoginItemService: LoginItemServiceManaging, @unchecked Sendable {
  private let lock = NSLock()
  private var registerCount = 0
  private var unregisterCount = 0
  private var pending: CheckedContinuation<Void, Never>?

  var status: ServiceRegistrationStatus { .notRegistered }

  func register() async throws {
    lock.withLock { registerCount += 1 }
    await withCheckedContinuation { continuation in
      lock.withLock { pending = continuation }
    }
  }

  func unregister() async throws {
    lock.withLock { unregisterCount += 1 }
  }

  func openSystemSettingsLoginItems() {}

  var registerCalls: Int { lock.withLock { registerCount } }
  var unregisterCalls: Int { lock.withLock { unregisterCount } }

  func waitUntilRegisterSuspended() async -> Bool {
    for _ in 0..<500 {
      if lock.withLock({ pending != nil }) {
        return true
      }
      try? await Task.sleep(for: .milliseconds(2))
    }
    return false
  }

  func resumeRegister() -> Bool {
    let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      let continuation = pending
      pending = nil
      return continuation
    }
    continuation?.resume()
    return continuation != nil
  }
}

private final class CountingLoginItemService: LoginItemServiceManaging, @unchecked Sendable {
  private let lock = NSLock()
  private var recordedOperations: [String] = []
  let status: ServiceRegistrationStatus

  init(status: ServiceRegistrationStatus) {
    self.status = status
  }

  func register() async throws {
    lock.withLock { recordedOperations.append("register") }
  }

  func unregister() async throws {
    lock.withLock { recordedOperations.append("unregister") }
  }

  func openSystemSettingsLoginItems() {}

  var operations: [String] { lock.withLock { recordedOperations } }
}

private struct StubLoginItemService: LoginItemServiceManaging {
  let status: ServiceRegistrationStatus
  func register() async throws {}
  func unregister() async throws {}
  func openSystemSettingsLoginItems() {}
}

private struct MockAppCatalog: AppDisplayResolving {
  func displayInfo(for bundleID: String) -> AppDisplayInfo {
    let names = [
      "com.apple.Safari": "Safari",
      "com.apple.Terminal": "Terminal",
    ]
    return AppDisplayInfo(
      bundleID: bundleID,
      displayName: names[bundleID] ?? bundleID,
      url: names[bundleID].map { URL(fileURLWithPath: "/Applications/\($0).app") }
    )
  }

  func identity(forApplicationURL url: URL) -> AppIdentity? { nil }
  func installedApplications() -> [AppDisplayInfo] { [] }
}

private enum MockError: LocalizedError {
  case saveFailed
  case reloadFailed

  var errorDescription: String? {
    switch self {
    case .saveFailed:
      "The configuration could not be saved."
    case .reloadFailed:
      "The agent could not reload."
    }
  }
}

private func healthyStatus(bindingCount: Int = 0) -> AgentStatus {
  AgentStatus(
    agentVersion: "test",
    accessibilityGranted: true,
    inputMonitoringGranted: true,
    tapActive: true,
    configState: .ok,
    bindingCount: bindingCount,
    lastReloadError: nil
  )
}
