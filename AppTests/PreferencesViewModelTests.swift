import Foundation
import SummondCore
import Testing

@testable import Summond

@MainActor
@Suite("Preferences view model")
struct PreferencesViewModelTests {
  @Test("Shortcut formatter emits glyph tokens in macOS display order")
  func shortcutFormatterTokens() {
    let shortcut = Shortcut(key: "space", mods: ["ctrl", "cmd", "alt"])

    // Control, Option, Shift, Command — the macOS modifier display order,
    // independent of how the modifiers are stored.
    #expect(ShortcutFormatter.tokens(for: shortcut) == ["⌃", "⌥", "⌘", "Space"])
    #expect(ShortcutFormatter.symbols(for: Shortcut(key: "a", mods: ["cmd", "shift"])) == "⇧⌘A")
    #expect(ShortcutFormatter.symbols(for: Shortcut(key: "home", mods: [])) == "Home")
    #expect(ShortcutFormatter.symbols(for: Shortcut(key: "end", mods: ["cmd"])) == "⌘End")
    #expect(ShortcutFormatter.tokens(for: ShortcutDraft.empty) == [])
  }

  @Test("Cautions about shortcuts that shadow normal typing")
  func cautionsAboutTypingShadowingShortcuts() {
    let model = PreferencesViewModel(
      store: MockConfigurationStore(loadResult: .fresh(.empty)),
      agentClient: MockAgentClient(),
      appCatalog: MockAppCatalog()
    )

    func caution(key: String, mods: [String]) -> String? {
      model.cautionMessage(
        for: BindingEditorDraft(
          purpose: .add,
          shortcut: ShortcutDraft(key: key, mods: mods),
          bundleID: "com.apple.Safari",
          mode: .launch
        )
      )
    }

    #expect(caution(key: "space", mods: []) != nil)  // bare typing key
    #expect(caution(key: "2", mods: ["shift"]) != nil)  // Shift+2 produces "@"
    #expect(caution(key: "a", mods: ["cmd"]) == nil)  // Command combination is safe
    #expect(caution(key: "f5", mods: []) == nil)  // function keys aren't typing keys
  }

  @Test("App fuzzy match ranks subsequence matches")
  func appFuzzyMatchRanking() {
    let apps = [
      AppDisplayInfo.installed(
        bundleID: "com.apple.TextEdit",
        displayName: "TextEdit",
        url: URL(fileURLWithPath: "/Applications/TextEdit.app")
      ),
      AppDisplayInfo.installed(
        bundleID: "com.apple.ActivityMonitor",
        displayName: "Activity Monitor",
        url: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
      ),
      AppDisplayInfo.installed(
        bundleID: "com.apple.Terminal",
        displayName: "Terminal",
        url: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
      ),
    ]

    #expect(AppFuzzyMatch.score("tm", "Activity Monitor") != nil)
    #expect(AppFuzzyMatch.score("zz", "Terminal") == nil)
    #expect(AppFuzzyMatch.rank(apps, "term").map(\.bundleID).first == "com.apple.Terminal")
    #expect(AppFuzzyMatch.rank(apps, "").map(\.bundleID) == apps.map(\.bundleID))
  }

  @Test("Adds, edits, and removes bindings through the persisted draft")
  func addEditRemoveDraftSemantics() async throws {
    let store = MockConfigurationStore(loadResult: .fresh(.empty))
    let agentClient = MockAgentClient()
    let model = PreferencesViewModel(
      store: store,
      agentClient: agentClient,
      appCatalog: MockAppCatalog()
    )

    model.beginAdding()
    model.editorDraft?.shortcut = ShortcutDraft(key: "f5", mods: ["cmd", "shift"])
    model.editorDraft?.bundleID = "com.apple.Safari"
    model.editorDraft?.mode = .newWindow

    await model.commitEditorDraftAndSave()

    let added = try #require(model.draft.bindings.first)
    #expect(model.editorDraft == nil)
    #expect(added.shortcut == Shortcut(key: "f5", mods: ["cmd", "shift"]))
    #expect(added.target.mode == .newWindow)
    #expect(store.savedConfigurations.count == 1)
    #expect(agentClient.reloadCount == 1)

    model.beginEditing(added)
    model.editorDraft?.mode = .move
    await model.commitEditorDraftAndSave()

    #expect(model.draft.bindings.first?.target.mode == .move)
    #expect(store.savedConfigurations.count == 2)

    await model.deleteBinding(id: added.id)

    #expect(model.draft.bindings.isEmpty)
    #expect(store.savedConfigurations.count == 3)
  }

  @Test("Re-opening the editor preserves an in-progress draft instead of discarding it")
  func reopeningEditorPreservesDraft() throws {
    let model = PreferencesViewModel(
      store: MockConfigurationStore(loadResult: .fresh(.empty)),
      agentClient: MockAgentClient(),
      appCatalog: MockAppCatalog()
    )

    model.beginAdding()
    model.editorDraft?.shortcut = ShortcutDraft(key: "a", mods: ["cmd"])
    model.editorDraft?.bundleID = "com.apple.Safari"
    let presentationID = model.editorPresentationID

    model.beginAdding()
    #expect(model.editorDraft?.shortcut.key == "a")
    #expect(model.editorDraft?.bundleID == "com.apple.Safari")
    #expect(model.editorPresentationID != presentationID)

    let existing = StoredBinding(
      shortcut: Shortcut(key: "f", mods: ["cmd"]),
      target: try AppTarget(bundleID: "com.apple.Terminal", mode: .launch)
    )
    model.beginEditing(existing)
    #expect(model.editorDraft?.shortcut.key == "a")
    #expect(model.editorDraft?.bundleID == "com.apple.Safari")
  }

  @Test("Duplicate shortcut validation names the conflicting binding")
  func duplicateShortcutValidationNamesConflict() throws {
    let existing = StoredBinding(
      shortcut: Shortcut(key: "f", mods: ["cmd"]),
      target: try AppTarget(bundleID: "com.apple.Safari", mode: .launch)
    )
    let model = PreferencesViewModel(
      store: MockConfigurationStore(
        loadResult: .loaded(SummondConfigurationV1(bindings: [existing]))
      ),
      agentClient: MockAgentClient(),
      appCatalog: MockAppCatalog()
    )

    let draft = BindingEditorDraft(
      purpose: .add,
      shortcut: ShortcutDraft(key: "f", mods: ["command"]),
      bundleID: "com.apple.Terminal",
      mode: .launch
    )

    #expect(
      model.validationMessages(for: draft)
        .contains("Duplicates ⌘F for Safari.")
    )
  }

  @Test("Corrupt reset writes an empty valid configuration")
  func corruptResetWritesEmptyConfiguration() async throws {
    let store = MockConfigurationStore(loadResult: .corrupt(.undecodable("bad json")))
    let agentClient = MockAgentClient()
    let model = PreferencesViewModel(
      store: store,
      agentClient: agentClient,
      appCatalog: MockAppCatalog()
    )

    guard case .corrupt = model.loadState else {
      Issue.record("Expected corrupt load state")
      return
    }

    await model.resetCorruptConfiguration()

    #expect(store.savedConfigurations == [.empty])
    #expect(model.draft == .empty)
    #expect(model.loadState == .loaded)
    #expect(agentClient.reloadCount == 1)
  }

  @Test("Save failure preserves the user's draft")
  func saveFailurePreservesDraft() async {
    let store = MockConfigurationStore(
      loadResult: .fresh(.empty),
      saveError: MockError.saveFailed
    )
    let model = PreferencesViewModel(
      store: store,
      agentClient: MockAgentClient(),
      appCatalog: MockAppCatalog()
    )

    model.beginAdding()
    model.editorDraft?.shortcut = ShortcutDraft(key: "a", mods: ["cmd"])
    model.editorDraft?.bundleID = "com.apple.Safari"

    await model.commitEditorDraftAndSave()

    // A failed save must not add the binding to the persisted list...
    #expect(model.draft.bindings.count == 0)
    // ...but the editor sheet keeps the user's in-progress work so they can retry.
    #expect(model.editorDraft != nil)
    #expect(model.editorDraft?.shortcut.key == "a")
    #expect(model.banner?.title == "Changes were not saved")
  }
}

private final class MockConfigurationStore: @unchecked Sendable, ConfigurationStore {
  var loadResult: ConfigurationLoadResult
  var saveError: Error?
  var savedConfigurations: [SummondConfigurationV1] = []

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
  var reloadCount = 0

  func status() async throws -> AgentStatus {
    makeStatus()
  }

  func reloadConfiguration() async throws -> AgentStatus {
    reloadCount += 1
    return makeStatus()
  }

  func requestAccessibilityPrompt() {}
  func requestInputMonitoringPrompt() {}

  private func makeStatus() -> AgentStatus {
    AgentStatus(
      agentVersion: "test",
      accessibilityGranted: true,
      inputMonitoringGranted: true,
      tapActive: true,
      configState: .ok,
      bindingCount: 0,
      lastReloadError: nil
    )
  }
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
      url: nil,
      isInstalled: names[bundleID] != nil
    )
  }

  func identity(forApplicationURL url: URL) -> AppIdentity? {
    nil
  }

  func installedApplications() -> [AppDisplayInfo] {
    []
  }
}

private enum MockError: Error {
  case saveFailed
}
