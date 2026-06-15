import CoreGraphics
import Foundation
import SummondCore
import Observation

@MainActor
@Observable
final class PreferencesViewModel {
  enum LoadState: Equatable {
    case fresh
    case loaded
    case corrupt(ConfigurationCorruption)
  }

  private let store: any ConfigurationStore
  private let agentClient: any AgentClientProtocol
  private let appCatalog: any AppDisplayResolving

  var draft: SummondConfigurationV1
  var loadState: LoadState = .fresh
  var banner: PreferencesBanner?
  var isSaving = false
  var editorDraft: BindingEditorDraft?
  var editorPresentationID = UUID()
  var installedApplications: [AppDisplayInfo] = []
  var installedAppsLoaded = false
  var installedAppsLoading = false

  /// Invoked with the agent's status after a successful configuration reload so
  /// the owner (e.g. ServiceManager) can sync without an observable diff, which
  /// would silently skip identical-valued reloads.
  @ObservationIgnored
  var onAgentStatusReloaded: (@MainActor (AgentStatus) -> Void)?

  init(
    store: any ConfigurationStore,
    agentClient: any AgentClientProtocol,
    appCatalog: any AppDisplayResolving = InstalledAppCatalog(),
    initialBanner: PreferencesBanner? = nil
  ) {
    self.store = store
    self.agentClient = agentClient
    self.appCatalog = appCatalog
    self.banner = initialBanner

    switch store.load() {
    case .fresh(let configuration):
      draft = configuration
      loadState = .fresh
    case .loaded(let configuration):
      draft = configuration
      loadState = .loaded
    case .corrupt(let corruption):
      draft = .empty
      loadState = .corrupt(corruption)
      banner = PreferencesBanner(
        tone: .warning,
        title: "Configuration could not be loaded",
        message: corruption.localizedDescription
      )
    }
  }

  func displayInfo(for bundleID: String) -> AppDisplayInfo {
    appCatalog.displayInfo(for: bundleID)
  }

  func loadInstalledApplicationsIfNeeded() async {
    guard !installedAppsLoaded, !installedAppsLoading else {
      return
    }
    installedAppsLoading = true
    installedApplications = await appCatalog.installedApplications()
    installedAppsLoaded = true
    installedAppsLoading = false
  }

  func identity(forApplicationURL url: URL) -> AppIdentity? {
    appCatalog.identity(forApplicationURL: url)
  }

  func beginAdding() {
    editorDraft = BindingEditorDraft(
      purpose: .add,
      shortcut: .empty,
      bundleID: "",
      mode: .launch
    )
    #if DEBUG
      if UITestHarness.isActive, let shortcut = UITestHarness.prefilledDraftShortcut {
        editorDraft?.shortcut = shortcut
      }
    #endif
    editorPresentationID = UUID()
  }

  func beginEditing(_ binding: StoredBinding) {
    editorDraft = BindingEditorDraft(
      purpose: .edit(binding.id),
      shortcut: ShortcutDraft(key: binding.shortcut.key, mods: binding.shortcut.mods),
      bundleID: binding.target.bundleID,
      mode: binding.target.mode
    )
    editorPresentationID = UUID()
  }

  func cancelEditing() {
    editorDraft = nil
  }

  func recordShortcut(keyCode: CGKeyCode, flags: CGEventFlags) -> String? {
    let relevantFlags = flags.intersection(KeyCode.relevantModifiersMask)
    guard let keyName = KeyCode.name(for: keyCode) else {
      return "That key is not supported by Summond yet."
    }

    guard var editorDraft else {
      return nil
    }
    editorDraft.shortcut = ShortcutDraft(
      key: keyName,
      mods: KeyCode.modifierNames(for: relevantFlags)
    )
    self.editorDraft = editorDraft
    return nil
  }

  func validationMessages(for editorDraft: BindingEditorDraft) -> [String] {
    var messages: [String] = []

    guard let shortcut = editorDraft.shortcut.shortcut else {
      messages.append("Record a shortcut.")
      return messages
    }

    do {
      _ = try BindingCompiler.compileShortcut(shortcut)
    } catch {
      messages.append(error.localizedDescription)
    }

    do {
      _ = try AppTarget(bundleID: editorDraft.bundleID, mode: editorDraft.mode)
    } catch {
      messages.append(error.localizedDescription)
    }

    if let conflict = conflictingBinding(
      with: shortcut,
      excluding: editorDraft.editingID
    ) {
      let info = displayInfo(for: conflict.target.bundleID)
      messages.append(
        "Duplicates \(ShortcutFormatter.symbols(for: conflict.shortcut)) for \(info.displayName)."
      )
    }

    return messages
  }

  func cautionMessage(for editorDraft: BindingEditorDraft) -> String? {
    guard let shortcut = editorDraft.shortcut.shortcut else {
      return nil
    }

    // A shortcut shadows normal typing when its only modifier is Shift (or it
    // has none) on a key that produces literal text — e.g. bare Space, or
    // Shift+2 ("@"). Command/Option/Control combinations are safe.
    let onlyShiftOrNone = shortcut.mods.allSatisfy { $0.lowercased() == "shift" }
    guard onlyShiftOrNone, KeyCode.producesLiteralText(shortcut.key) else {
      return nil
    }

    return "This will capture every press of this shortcut system-wide."
  }

  func commitEditorDraftAndSave() async {
    guard let editorDraft else {
      return
    }

    let messages = validationMessages(for: editorDraft)
    guard messages.isEmpty else {
      banner = PreferencesBanner(
        tone: .error,
        title: "Binding is not valid",
        message: messages.joined(separator: "\n")
      )
      return
    }

    guard
      let shortcut = editorDraft.shortcut.shortcut,
      let target = try? AppTarget(bundleID: editorDraft.bundleID, mode: editorDraft.mode)
    else {
      return
    }

    var next = draft
    let binding = StoredBinding(
      id: editorDraft.editingID ?? UUID(),
      shortcut: shortcut,
      target: target
    )

    switch editorDraft.purpose {
    case .add:
      next.bindings.append(binding)
    case .edit(let id):
      guard let index = next.bindings.firstIndex(where: { $0.id == id }) else {
        banner = PreferencesBanner(
          tone: .error,
          title: "Binding no longer exists",
          message: "Refresh the configuration and try again."
        )
        return
      }
      next.bindings[index] = binding
    }

    await persist(next)
    if banner?.tone != .error {
      self.editorDraft = nil
    }
  }

  func deleteBinding(id: UUID) async {
    var next = draft
    next.bindings.removeAll { $0.id == id }
    await persist(next)
  }

  func setVerboseLogging(_ isEnabled: Bool) async {
    var next = draft
    next.verboseLogging = isEnabled
    await persist(next)
  }

  func resetCorruptConfiguration() async {
    await persist(.empty)
  }

  private func persist(_ next: SummondConfigurationV1) async {
    isSaving = true
    defer { isSaving = false }

    do {
      // store.save validates the configuration, so this is the single
      // validation gate on the persistence path.
      try store.save(next)
      draft = next
      loadState = .loaded
    } catch {
      banner = PreferencesBanner(
        tone: .error,
        title: "Changes were not saved",
        message: error.localizedDescription
      )
      return
    }

    do {
      let status = try await agentClient.reloadConfiguration()
      onAgentStatusReloaded?(status)
      banner = nil
    } catch {
      banner = PreferencesBanner(
        tone: .warning,
        title: "Changes were saved, but the agent did not reload",
        message: error.localizedDescription
      )
    }
  }

  private func conflictingBinding(
    with shortcut: Shortcut,
    excluding excludedID: UUID?
  ) -> StoredBinding? {
    guard let compiledShortcut = try? BindingCompiler.compileShortcut(shortcut) else {
      return nil
    }

    return draft.bindings.first { binding in
      guard binding.id != excludedID else {
        return false
      }
      return (try? BindingCompiler.compileShortcut(binding.shortcut)) == compiledShortcut
    }
  }
}
