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
    let store = MockConfigurationStore()
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
      configuration: SummondConfiguration(bindings: [existing])
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
      saveError: MockError.saveFailed
    )
    let model = makeModel(store: store)

    let result = await model.saveShortcut(draft(key: "a", mods: ["cmd"]))

    #expect(result == .failed(MockError.saveFailed.localizedDescription))
    #expect(model.configuration.bindings.isEmpty)
    #expect(model.configurationError == MockError.saveFailed.localizedDescription)
  }

  @Test("Corruption discovered during save recovers the configuration still in memory")
  func saveDiscoveredCorruption() async throws {
    let corruption = ConfigurationCorruption.undecodable("changed on disk")
    let existing = SummondConfiguration(
      bindings: [
        StoredBinding(
          shortcut: Shortcut(key: "f5", mods: ["cmd"]),
          target: try AppTarget(bundleID: "com.apple.Safari", mode: .launch)
        )
      ])
    let store = MockConfigurationStore(configuration: existing, saveError: corruption)
    let model = makeModel(store: store)

    #expect(await model.setVerboseLogging(true) == .failed(corruption.localizedDescription))
    #expect(model.loadState == .corrupt(corruption))
    #expect(model.canRecoverCorruptConfiguration)
    #expect(
      model.health
        == .degraded(.configurationCorrupt(details: corruption.localizedDescription)))

    #expect(await model.recoverCorruptConfiguration() == .saved)
    #expect(model.configuration == existing)
    #expect(store.replacedConfigurations == [existing])
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

  @Test("Startup corruption recovers to the empty configuration shown in the app")
  func startupCorruptionRecovery() async {
    let store = MockConfigurationStore(
      loadError: ConfigurationCorruption.undecodable("bad json")
    )
    let model = makeModel(store: store)

    guard case .corrupt = model.loadState else {
      Issue.record("Expected corrupt load state")
      return
    }
    #expect(model.canRecoverCorruptConfiguration)
    #expect(
      model.health
        == .degraded(
          .configurationCorrupt(
            details: "Configuration data could not be decoded: bad json"
          )))

    #expect(await model.recoverCorruptConfiguration() == .saved)
    #expect(store.replacedConfigurations == [.empty])
    #expect(model.configuration == .empty)
    #expect(model.loadState == .loaded)
  }

  @Test("Verbose logging uses the same persistence path")
  func verboseLogging() async {
    let store = MockConfigurationStore()
    let model = makeModel(store: store)

    #expect(await model.setVerboseLogging(true) == .saved)
    #expect(model.configuration.verboseLogging)
    #expect(store.savedConfigurations.map(\.verboseLogging) == [true])
  }

  @Test("Unavailable durable storage blocks mutations")
  func permanentStorageError() async {
    let message = MockError.loadFailed.localizedDescription
    let model = makeModel(store: MockConfigurationStore(loadError: MockError.loadFailed))

    #expect(await model.setVerboseLogging(true) == .failed(message))
    #expect(!model.configuration.verboseLogging)
    #expect(model.loadState == .unavailable(message))
    #expect(model.health == .degraded(.configurationUnavailable(details: message)))
  }

  @Test("Refresh retries the agent reload after storage recovers")
  func transientStorageError() async {
    let recovered = SummondConfiguration(verboseLogging: true)
    let store = MockConfigurationStore(loadError: MockError.loadFailed)
    let agent = MockAgentClient(reloadError: MockError.reloadFailed)
    let model = makeModel(store: store, agentClient: agent)
    store.loadError = nil
    store.configuration = recovered

    await model.refresh()

    #expect(model.configuration == recovered)
    #expect(model.loadState == .loaded)
    #expect(agent.reloadCount == 1)
    #expect(model.reloadError == MockError.reloadFailed.localizedDescription)

    agent.reloadError = nil
    await model.refresh()

    #expect(agent.reloadCount == 2)
    #expect(model.reloadError == nil)
    #expect(model.health == .ready(activeShortcuts: 0))
  }

  @Test("Permission requests keep their errors separate from service registration")
  func permissionRequestError() async {
    let operations = OperationRecorder()
    let service = RecordingLoginItemService(
      name: "agent",
      status: .notRegistered,
      operations: operations,
      registerErrors: [MockError.registerFailed]
    )
    let agent = MockAgentClient(promptError: MockError.statusFailed)
    let model = makeModel(agentClient: agent, agentService: service)

    await model.enableService()
    let serviceError = model.serviceError
    await model.requestAccessibilitySetup()

    #expect(model.permissionError == MockError.statusFailed.localizedDescription)
    #expect(model.serviceError == serviceError)

    await model.refresh()
    #expect(model.permissionError == nil)
    #expect(model.serviceError == serviceError)

    agent.promptError = MockError.statusFailed
    await model.requestAccessibilitySetup()
    agent.promptError = nil
    await model.requestAccessibilitySetup()
    #expect(model.permissionError == nil)
    #expect(model.serviceError == serviceError)
  }

  @Test("Failed status explains an enabled but unresponsive service")
  func failedStatusExplainsEnabledService() async {
    let model = makeModel(
      agentClient: MockAgentClient(statusError: MockError.statusFailed),
      agentService: StubLoginItemService(status: .enabled)
    )

    await model.refresh()

    #expect(model.agentConnectionError == MockError.statusFailed.localizedDescription)
    #expect(model.serviceError == nil)
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
    _ = await refresh.value

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
    let staleStatus = await refresh.value

    #expect(staleStatus?.bindingCount == 1)
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
    let operations = OperationRecorder()
    let service = RecordingLoginItemService(
      name: "agent", status: .enabled, operations: operations)
    let model = makeModel(agentService: service)

    await model.restartService()

    #expect(operations.values == ["agent.unregister", "agent.register"])
  }

  @Test("Restart retries registration without unregistering again")
  func restartServiceRetriesRegistration() async {
    let operations = OperationRecorder()
    let sleeps = OperationRecorder()
    let service = RecordingLoginItemService(
      name: "agent",
      status: .enabled,
      operations: operations,
      registerErrors: [MockError.registerFailed, MockError.registerFailed]
    )
    let model = makeModel(
      agentService: service,
      serviceSleep: { _ in sleeps.record("sleep") }
    )

    #expect(await model.restartService())
    #expect(
      operations.values == [
        "agent.unregister", "agent.register", "agent.register", "agent.register",
      ])
    #expect(sleeps.values.count == 4)
  }

  @Test("Service startup waits through transient agent connection failures")
  func serviceStartupWaitsForAgent() async {
    let agent = RetryingAgentClient(failuresBeforeSuccess: 2)
    let operations = OperationRecorder()
    let sleeps = OperationRecorder()
    let service = RecordingLoginItemService(
      name: "agent", status: .notRegistered, operations: operations)
    let model = makeModel(
      agentClient: agent,
      agentService: service,
      serviceSleep: { _ in sleeps.record("sleep") }
    )

    #expect(await model.enableService())
    #expect(await agent.statusCallCount == 3)
    #expect(sleeps.values.count == 3)
    #expect(model.agentStatus != nil)
    #expect(model.agentConnectionError == nil)
    #expect(model.serviceError == nil)
  }

  @Test("A new build refreshes each enabled service once")
  func newBuildRefreshesRegistrationsOnce() async {
    let suiteName = "net.garaba.summond.tests.registration.\(UUID().uuidString)"
    let defaults = try! #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("1", forKey: SummondModel.registeredAgentBuildKey)
    defaults.set("1", forKey: SummondModel.registeredStatusItemBuildKey)

    let operations = OperationRecorder()
    let model = makeModel(
      agentService: RecordingLoginItemService(
        name: "agent", status: .enabled, operations: operations),
      statusItemService: RecordingLoginItemService(
        name: "status", status: .enabled, operations: operations),
      registrationDefaults: defaults,
      buildVersion: "2"
    )

    await model.start()
    #expect(
      operations.values == [
        "agent.unregister", "agent.register", "status.unregister", "status.register",
      ])
    #expect(defaults.string(forKey: SummondModel.registeredAgentBuildKey) == "2")
    #expect(defaults.string(forKey: SummondModel.registeredStatusItemBuildKey) == "2")

    await model.start()
    #expect(operations.values.count == 4)
  }

  @Test("A failed agent refresh does not block the status item refresh")
  func failedAgentRefreshIsIndependent() async {
    let suiteName = "net.garaba.summond.tests.registration.\(UUID().uuidString)"
    let defaults = try! #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("1", forKey: SummondModel.registeredAgentBuildKey)
    defaults.set("1", forKey: SummondModel.registeredStatusItemBuildKey)

    let operations = OperationRecorder()
    let model = makeModel(
      agentService: RecordingLoginItemService(
        name: "agent",
        status: .enabled,
        operations: operations,
        registerErrors: Array(repeating: MockError.registerFailed, count: 3)
      ),
      statusItemService: RecordingLoginItemService(
        name: "status", status: .enabled, operations: operations),
      registrationDefaults: defaults,
      buildVersion: "2"
    )

    await model.start()

    #expect(
      operations.values == [
        "agent.unregister", "agent.register", "agent.register", "agent.register",
        "status.unregister", "status.register",
      ])
    #expect(defaults.string(forKey: SummondModel.registeredAgentBuildKey) == "1")
    #expect(defaults.string(forKey: SummondModel.registeredStatusItemBuildKey) == "2")
    #expect(model.serviceError == MockError.registerFailed.localizedDescription)
  }

  @Test("A service awaiting approval is never re-registered")
  func updatedRegistrationAwaitingApproval() async {
    let suiteName = "net.garaba.summond.tests.registration.\(UUID().uuidString)"
    let defaults = try! #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("1", forKey: SummondModel.registeredAgentBuildKey)

    let operations = OperationRecorder()
    let model = makeModel(
      agentService: RecordingLoginItemService(
        name: "agent",
        status: .requiresApproval,
        operations: operations
      ),
      registrationDefaults: defaults,
      buildVersion: "2"
    )

    await model.start()

    #expect(operations.values.isEmpty)
    #expect(defaults.string(forKey: SummondModel.registeredAgentBuildKey) == "1")
  }

  @Test("A current but unresponsive agent registration repairs itself")
  func unresponsiveAgentRepairsItself() async {
    let suiteName = "net.garaba.summond.tests.registration.\(UUID().uuidString)"
    let defaults = try! #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("2", forKey: SummondModel.registeredAgentBuildKey)

    let operations = OperationRecorder()
    let model = makeModel(
      agentClient: RetryingAgentClient(failuresBeforeSuccess: 1),
      agentService: RecordingLoginItemService(
        name: "agent", status: .enabled, operations: operations),
      registrationDefaults: defaults,
      buildVersion: "2"
    )

    await model.start()

    #expect(operations.values == ["agent.unregister", "agent.register"])
    #expect(model.agentStatus != nil)
  }

  @Test("An enabled status item repairs itself when it is not running")
  func stoppedStatusItemRepairsItself() async {
    let suiteName = "net.garaba.summond.tests.registration.\(UUID().uuidString)"
    let defaults = try! #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("2", forKey: SummondModel.registeredStatusItemBuildKey)

    let operations = OperationRecorder()
    let model = makeModel(
      agentService: StubLoginItemService(status: .notRegistered),
      statusItemService: RecordingLoginItemService(
        name: "status", status: .enabled, operations: operations),
      registrationDefaults: defaults,
      buildVersion: "2",
      isStatusItemRunning: { false }
    )

    await model.start()

    #expect(operations.values == ["status.unregister", "status.register"])
  }

  @Test("A forced refresh re-registers both enabled services")
  func forcedRefreshReRegistersBothServices() async {
    let operations = OperationRecorder()
    let model = makeModel(
      agentService: RecordingLoginItemService(
        name: "agent", status: .enabled, operations: operations),
      statusItemService: RecordingLoginItemService(
        name: "status", status: .enabled, operations: operations),
      isStatusItemRunning: { true }
    )

    #expect(await model.refreshEnabledServices())
    #expect(
      operations.values == [
        "agent.unregister", "agent.register", "status.unregister", "status.register",
      ])
  }

  @Test("Uninstall preparation unregisters the agent before the menu bar item")
  func prepareForUninstallInOrder() async {
    let operations = OperationRecorder()
    let agent = RecordingLoginItemService(
      name: "agent", status: .enabled, operations: operations)
    let statusItem = RecordingLoginItemService(
      name: "status", status: .requiresApproval, operations: operations)
    let savedData = MockSavedDataRemover()
    let model = makeModel(
      agentService: agent,
      statusItemService: statusItem,
      savedDataRemover: savedData
    )

    #expect(await model.prepareForUninstall(deleteSavedData: false))
    #expect(operations.values == ["agent.unregister", "status.unregister"])
    #expect(agent.status == .notRegistered)
    #expect(statusItem.status == .notRegistered)
    #expect(savedData.removeCalls == 0)
    #expect(model.uninstallPreparationError == nil)
  }

  @Test("Uninstall preparation skips absent components and optionally deletes data")
  func prepareForUninstallSkipsAbsentComponents() async {
    let operations = OperationRecorder()
    let savedData = MockSavedDataRemover()
    let model = makeModel(
      agentService: RecordingLoginItemService(
        name: "agent", status: .notRegistered, operations: operations),
      statusItemService: RecordingLoginItemService(
        name: "status", status: .notFound, operations: operations),
      savedDataRemover: savedData
    )

    #expect(await model.prepareForUninstall(deleteSavedData: true))
    #expect(operations.values.isEmpty)
    #expect(savedData.removeCalls == 1)
  }

  @Test("Saved data cleanup covers every Summond preferences domain")
  func savedDataCleanupDomains() {
    #expect(
      Set(LocalSavedDataRemover.summondDomainNames) == [
        SummondBundleIdentifiers.app,
        SummondBundleIdentifiers.agent,
        SummondBundleIdentifiers.statusItem,
      ])
  }

  @Test("Saved data remover clears preferences and the configuration file")
  func savedDataRemoverClearsDomainsAndConfiguration() throws {
    let domainNames = [
      "net.garaba.summond.tests.uninstall.\(UUID().uuidString)",
      "net.garaba.summond.tests.uninstall.\(UUID().uuidString)",
    ]
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let configurationURL = directory.appendingPathComponent("configuration.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("saved".utf8).write(to: configurationURL)
    defer {
      for domainName in domainNames {
        UserDefaults.standard.removePersistentDomain(forName: domainName)
      }
      try? FileManager.default.removeItem(at: directory)
    }
    for domainName in domainNames {
      UserDefaults.standard.setPersistentDomain(["value": "saved"], forName: domainName)
      #expect(UserDefaults.standard.persistentDomain(forName: domainName) != nil)
    }

    try LocalSavedDataRemover(
      domainNames: domainNames,
      configurationDirectoryURL: directory
    ).removeAllSavedData()

    for domainName in domainNames {
      #expect(UserDefaults.standard.persistentDomain(forName: domainName) == nil)
    }
    #expect(!FileManager.default.fileExists(atPath: configurationURL.path))
  }

  @Test("Saved data deletion failure stops uninstall preparation")
  func savedDataDeletionFailureStopsUninstall() async {
    let savedData = MockSavedDataRemover(error: MockError.saveFailed)
    let model = makeModel(
      agentService: StubLoginItemService(status: .notRegistered),
      statusItemService: StubLoginItemService(status: .notFound),
      savedDataRemover: savedData
    )

    #expect(!(await model.prepareForUninstall(deleteSavedData: true)))
    #expect(savedData.removeCalls == 1)
    #expect(
      model.uninstallPreparationError
        == "Saved shortcuts and settings could not be deleted: The configuration could not be saved."
    )
  }

  @Test("Agent unregister failure stops uninstall preparation immediately")
  func prepareForUninstallStopsAfterAgentFailure() async {
    let operations = OperationRecorder()
    let savedData = MockSavedDataRemover()
    let model = makeModel(
      agentService: RecordingLoginItemService(
        name: "agent",
        status: .enabled,
        operations: operations,
        unregisterErrors: [MockError.unregisterFailed]
      ),
      statusItemService: RecordingLoginItemService(
        name: "status", status: .enabled, operations: operations),
      savedDataRemover: savedData
    )

    #expect(!(await model.prepareForUninstall(deleteSavedData: true)))
    #expect(operations.values == ["agent.unregister"])
    #expect(savedData.removeCalls == 0)
    #expect(model.uninstallPreparationError?.contains("background service") == true)
  }

  @Test("Thrown unregister fails preparation even when the component ended up unregistered")
  func prepareForUninstallTreatsThrownUnregisterAsFailure() async {
    let operations = OperationRecorder()
    let savedData = MockSavedDataRemover()
    let model = makeModel(
      agentService: RecordingLoginItemService(
        name: "agent",
        status: .enabled,
        operations: operations,
        unregisterErrors: [MockError.unregisterFailed],
        unregistersBeforeThrowing: true
      ),
      statusItemService: RecordingLoginItemService(
        name: "status", status: .enabled, operations: operations),
      savedDataRemover: savedData
    )

    #expect(!(await model.prepareForUninstall(deleteSavedData: true)))
    #expect(operations.values == ["agent.unregister"])
    #expect(savedData.removeCalls == 0)
    #expect(model.uninstallPreparationError?.contains("background service") == true)

    #expect(await model.prepareForUninstall(deleteSavedData: true))
    #expect(operations.values == ["agent.unregister", "status.unregister"])
    #expect(savedData.removeCalls == 1)
  }

  @Test("Menu bar failure preserves data and retry skips the removed agent")
  func prepareForUninstallRetriesStatusItem() async {
    let operations = OperationRecorder()
    let savedData = MockSavedDataRemover()
    let agent = RecordingLoginItemService(
      name: "agent", status: .enabled, operations: operations)
    let statusItem = RecordingLoginItemService(
      name: "status",
      status: .enabled,
      operations: operations,
      unregisterErrors: [MockError.unregisterFailed]
    )
    let model = makeModel(
      agentService: agent,
      statusItemService: statusItem,
      savedDataRemover: savedData
    )

    #expect(!(await model.prepareForUninstall(deleteSavedData: true)))
    #expect(operations.values == ["agent.unregister", "status.unregister"])
    #expect(savedData.removeCalls == 0)
    #expect(model.uninstallPreparationError?.contains("menu bar item") == true)

    #expect(await model.prepareForUninstall(deleteSavedData: true))
    #expect(
      operations.values == ["agent.unregister", "status.unregister", "status.unregister"])
    #expect(savedData.removeCalls == 1)
  }

  @Test("Uninstall preparation blocks overlapping service operations")
  func prepareForUninstallBlocksOtherOperations() async throws {
    let agent = SuspendingUnregisterLoginItemService()
    let statusOperations = OperationRecorder()
    let statusItem = RecordingLoginItemService(
      name: "status", status: .notRegistered, operations: statusOperations)
    let model = makeModel(agentService: agent, statusItemService: statusItem)

    let preparation = Task { await model.prepareForUninstall(deleteSavedData: false) }
    try #require(await agent.waitUntilUnregisterSuspended())

    await model.enableService()
    await model.setStatusItemShown(true)
    #expect(agent.registerCalls == 0)
    #expect(statusOperations.values.isEmpty)

    agent.resumeUnregister()
    #expect(await preparation.value)
    #expect(!model.isPreparingToUninstall)
  }

  private func makeModel(
    store: MockConfigurationStore = MockConfigurationStore(),
    agentClient: any AgentClientProtocol = MockAgentClient(),
    agentService: any LoginItemServiceManaging = StubLoginItemService(status: .enabled),
    statusItemService: any LoginItemServiceManaging = StubLoginItemService(status: .notRegistered),
    savedDataRemover: any SavedDataRemoving = MockSavedDataRemover(),
    registrationDefaults: UserDefaults = .standard,
    buildVersion: String = "test-build",
    serviceSleep: @escaping @Sendable (Duration) async -> Void = { _ in },
    isStatusItemRunning: @escaping @Sendable () -> Bool = { true }
  ) -> SummondModel {
    SummondModel(
      storage: store,
      agentClient: agentClient,
      agentService: agentService,
      statusItemService: statusItemService,
      appCatalog: MockAppCatalog(),
      savedDataRemover: savedDataRemover,
      registrationDefaults: registrationDefaults,
      buildVersion: buildVersion,
      serviceSleep: serviceSleep,
      isStatusItemRunning: isStatusItemRunning
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
  var configuration: SummondConfiguration?
  var loadError: Error?
  var saveError: Error?
  private(set) var savedConfigurations: [SummondConfiguration] = []
  private(set) var replacedConfigurations: [SummondConfiguration] = []

  init(
    configuration: SummondConfiguration? = nil,
    loadError: Error? = nil,
    saveError: Error? = nil
  ) {
    self.configuration = configuration
    self.loadError = loadError
    self.saveError = saveError
  }

  func load() throws -> SummondConfiguration? {
    if let loadError {
      throw loadError
    }
    return configuration
  }

  func save(_ configuration: SummondConfiguration) throws {
    if let saveError {
      throw saveError
    }
    self.configuration = configuration
    savedConfigurations.append(configuration)
  }

  func replace(with configuration: SummondConfiguration) {
    self.configuration = configuration
    loadError = nil
    replacedConfigurations.append(configuration)
  }
}

private final class MockAgentClient: @unchecked Sendable, AgentClientProtocol {
  var statusValue: AgentStatus
  var reloadStatus: AgentStatus
  var statusError: Error?
  var reloadError: Error?
  var promptError: Error?
  private(set) var reloadCount = 0

  init(
    status: AgentStatus = healthyStatus(),
    reloadStatus: AgentStatus = healthyStatus(),
    statusError: Error? = nil,
    reloadError: Error? = nil,
    promptError: Error? = nil
  ) {
    self.statusValue = status
    self.reloadStatus = reloadStatus
    self.statusError = statusError
    self.reloadError = reloadError
    self.promptError = promptError
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

  func requestAccessibilityPrompt() async throws {
    if let promptError { throw promptError }
  }
}

private actor RetryingAgentClient: AgentClientProtocol {
  private var failuresRemaining: Int
  private(set) var statusCallCount = 0

  init(failuresBeforeSuccess: Int) {
    failuresRemaining = failuresBeforeSuccess
  }

  func status() async throws -> AgentStatus {
    statusCallCount += 1
    if failuresRemaining > 0 {
      failuresRemaining -= 1
      throw MockError.statusFailed
    }
    return healthyStatus()
  }

  func reloadConfiguration() async throws -> AgentStatus { healthyStatus() }
  func requestAccessibilityPrompt() async throws {}
}

private actor CancellableAgentClient: AgentClientProtocol {
  private var statusCalls = 0
  private var secondCallWaiter: CheckedContinuation<Void, Never>?

  func status() async throws -> AgentStatus {
    statusCalls += 1
    if statusCalls == 2 {
      secondCallWaiter?.resume()
      secondCallWaiter = nil
    }
    if statusCalls > 1 {
      try await Task.sleep(for: .seconds(30))
    }
    return healthyStatus()
  }

  func reloadConfiguration() async throws -> AgentStatus { healthyStatus() }
  func requestAccessibilityPrompt() async throws {}

  func waitUntilSecondCallStarts() async {
    guard statusCalls < 2 else { return }
    await withCheckedContinuation { continuation in
      secondCallWaiter = continuation
    }
  }
}

private actor RacingAgentClient: AgentClientProtocol {
  private var statusContinuation: CheckedContinuation<AgentStatus, Never>?
  private var statusStartWaiter: CheckedContinuation<Void, Never>?

  func status() async -> AgentStatus {
    await withCheckedContinuation { continuation in
      statusContinuation = continuation
      statusStartWaiter?.resume()
      statusStartWaiter = nil
    }
  }

  func reloadConfiguration() async -> AgentStatus {
    healthyStatus(bindingCount: 7)
  }

  func requestAccessibilityPrompt() async throws {}

  func waitUntilStatusStarts() async {
    guard statusContinuation == nil else { return }
    await withCheckedContinuation { continuation in
      statusStartWaiter = continuation
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

private final class OperationRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedValues: [String] = []

  func record(_ value: String) {
    lock.withLock { recordedValues.append(value) }
  }

  var values: [String] { lock.withLock { recordedValues } }
}

private final class RecordingLoginItemService: LoginItemServiceManaging, @unchecked Sendable {
  private let lock = NSLock()
  private let name: String
  private let operations: OperationRecorder
  private let unregistersBeforeThrowing: Bool
  private let statusAfterRegister: ServiceRegistrationStatus
  private var currentStatus: ServiceRegistrationStatus
  private var registerErrors: [Error]
  private var unregisterErrors: [Error]

  init(
    name: String,
    status: ServiceRegistrationStatus,
    operations: OperationRecorder,
    registerErrors: [Error] = [],
    unregisterErrors: [Error] = [],
    unregistersBeforeThrowing: Bool = false,
    statusAfterRegister: ServiceRegistrationStatus = .enabled
  ) {
    self.name = name
    currentStatus = status
    self.operations = operations
    self.registerErrors = registerErrors
    self.unregisterErrors = unregisterErrors
    self.unregistersBeforeThrowing = unregistersBeforeThrowing
    self.statusAfterRegister = statusAfterRegister
  }

  var status: ServiceRegistrationStatus { lock.withLock { currentStatus } }

  func register() async throws {
    operations.record("\(name).register")
    let error = lock.withLock { registerErrors.isEmpty ? nil : registerErrors.removeFirst() }
    if let error {
      throw error
    }
    lock.withLock { currentStatus = statusAfterRegister }
  }

  func unregister() async throws {
    operations.record("\(name).unregister")
    let error = lock.withLock { unregisterErrors.isEmpty ? nil : unregisterErrors.removeFirst() }
    if let error {
      if unregistersBeforeThrowing {
        lock.withLock { currentStatus = .notRegistered }
      }
      throw error
    }
    lock.withLock { currentStatus = .notRegistered }
  }

  func openSystemSettingsLoginItems() {}
}

private final class SuspendingUnregisterLoginItemService: LoginItemServiceManaging,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var currentStatus: ServiceRegistrationStatus = .enabled
  private var pendingUnregister: CheckedContinuation<Void, Never>?
  private var registerCount = 0

  var status: ServiceRegistrationStatus { lock.withLock { currentStatus } }

  func register() async throws {
    lock.withLock { registerCount += 1 }
  }

  func unregister() async throws {
    await withCheckedContinuation { continuation in
      lock.withLock { pendingUnregister = continuation }
    }
    lock.withLock { currentStatus = .notRegistered }
  }

  func openSystemSettingsLoginItems() {}

  var registerCalls: Int { lock.withLock { registerCount } }

  func waitUntilUnregisterSuspended() async -> Bool {
    for _ in 0..<500 {
      if lock.withLock({ pendingUnregister != nil }) {
        return true
      }
      try? await Task.sleep(for: .milliseconds(2))
    }
    return false
  }

  func resumeUnregister() {
    let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      let continuation = pendingUnregister
      pendingUnregister = nil
      return continuation
    }
    continuation?.resume()
  }
}

private final class MockSavedDataRemover: SavedDataRemoving, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  private let error: Error?

  init(error: Error? = nil) {
    self.error = error
  }

  func removeAllSavedData() throws {
    lock.withLock { count += 1 }
    if let error { throw error }
  }

  var removeCalls: Int { lock.withLock { count } }
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
  case loadFailed
  case saveFailed
  case reloadFailed
  case statusFailed
  case registerFailed
  case unregisterFailed

  var errorDescription: String? {
    switch self {
    case .loadFailed:
      "The configuration could not be loaded."
    case .saveFailed:
      "The configuration could not be saved."
    case .reloadFailed:
      "The agent could not reload."
    case .statusFailed:
      "The agent status could not be read."
    case .registerFailed:
      "The login item could not start."
    case .unregisterFailed:
      "The login item could not stop."
    }
  }
}

private func healthyStatus(bindingCount: Int = 0) -> AgentStatus {
  AgentStatus(
    agentVersion: "test",
    accessibilityGranted: true,
    shortcutsActive: true,
    configState: .ok,
    bindingCount: bindingCount,
    lastReloadError: nil
  )
}
