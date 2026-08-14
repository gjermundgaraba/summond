import SummondCore
import SwiftUI

struct ContentView: View {
  var model: SummondModel

  @Environment(\.openSettings) private var openSettings
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage("hasPresentedInitialSetup") private var hasPresentedInitialSetup = false
  @State private var selection: StoredBinding.ID?
  @State private var presentedSheet: MainSheet?
  @State private var pendingDeletion: StoredBinding?
  @State private var confirmsConfigurationRecovery = false
  @State private var addShortcutAfterSetup = false

  var body: some View {
    VStack(spacing: 0) {
      notices

      BindingListView(
        bindings: model.configuration.bindings,
        selection: $selection,
        displayInfo: model.displayInfo,
        onAdd: presentAddShortcut,
        onEdit: presentEditShortcut,
        onDelete: requestDeletion
      )
      .padding(.horizontal, 16)
      .padding(.top, hasNotice ? 10 : 16)

      HealthStatusStrip(health: model.health)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }
    .toolbar { toolbar }
    .sheet(item: $presentedSheet, onDismiss: sheetDismissed) { sheet in
      switch sheet {
      case .setup:
        SetupAssistantView(
          model: model,
          showsFirstShortcutAction: model.configuration.bindings.isEmpty,
          onDismiss: finishInitialSetupPresentation,
          onAddFirstShortcut: { addShortcutAfterSetup = true }
        )
      case .shortcut(let draft):
        ShortcutEditorSession(
          model: model,
          initialDraft: draft,
          onDismiss: { presentedSheet = nil }
        )
      }
    }
    .confirmationDialog(
      "Delete Shortcut?",
      isPresented: Binding(
        get: { pendingDeletion != nil },
        set: { if !$0 { pendingDeletion = nil } }
      ),
      presenting: pendingDeletion
    ) { shortcut in
      Button("Delete Shortcut", role: .destructive) {
        delete(shortcut)
      }
      Button("Cancel", role: .cancel) {}
    } message: { shortcut in
      let app = model.displayInfo(for: shortcut.target.bundleID).displayName
      Text("\(ShortcutFormatter.symbols(for: shortcut.shortcut)) for \(app) will be removed.")
    }
    .confirmationDialog(
      "Recover Configuration?",
      isPresented: $confirmsConfigurationRecovery
    ) {
      Button("Replace Unreadable File", role: .destructive) {
        Task { await model.recoverCorruptConfiguration() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This replaces unreadable saved data with the configuration currently shown.")
    }
    .task {
      if !hasPresentedInitialSetup {
        presentedSheet = .setup
      }
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      Task { await model.refresh() }
    }
    .onOpenURL(perform: handleURL)
    .focusedValue(
      \.shortcutCommands,
      ShortcutCommands(
        add: presentAddShortcut,
        edit: editSelection,
        delete: deleteSelection,
        canEdit: selectedBinding != nil,
        canDelete: selectedBinding != nil && !model.isSaving
      )
    )
  }

  @ViewBuilder
  private var notices: some View {
    switch model.health {
    case .ready:
      EmptyView()
    case .degraded(.configurationCorrupt(let details)):
      NoticeBanner(
        symbol: "exclamationmark.triangle.fill",
        color: .orange,
        title: "Configuration Could Not Be Loaded",
        message: details ?? "The saved configuration could not be read.",
        actionTitle: model.canRecoverCorruptConfiguration ? "Recover" : nil,
        actionIdentifier: "configuration.recoverButton",
        action: { confirmsConfigurationRecovery = true }
      )
      .accessibilityIdentifier("configuration.notice")
      .padding([.horizontal, .top], 16)
    case .setupRequired(let requirement):
      SystemHealthBanner(notice: HealthNotice(setup: requirement)) { action in
        perform(action)
      }
      .padding([.horizontal, .top], 16)
    case .degraded(let issue):
      SystemHealthBanner(notice: HealthNotice(issue: issue)) { action in
        perform(action)
      }
      .padding([.horizontal, .top], 16)
    }
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      Button(action: presentAddShortcut) {
        Label("Add Shortcut", systemImage: "plus")
      }
      .help("Add shortcut")
      .accessibilityIdentifier("toolbar.addShortcut")

      Button(action: editSelection) {
        Label("Edit Shortcut", systemImage: "pencil")
      }
      .help("Edit selected shortcut")
      .disabled(selectedBinding == nil)
      .accessibilityIdentifier("toolbar.editShortcut")

      Button(action: deleteSelection) {
        Label("Delete Shortcut", systemImage: "trash")
      }
      .help("Delete selected shortcut")
      .disabled(selectedBinding == nil || model.isSaving)
      .accessibilityIdentifier("toolbar.deleteShortcut")
    }
  }

  private var selectedBinding: StoredBinding? {
    guard let selection else { return nil }
    return model.configuration.bindings.first { $0.id == selection }
  }

  private var hasNotice: Bool {
    if case .ready = model.health { return false }
    return true
  }

  private func presentAddShortcut() {
    guard presentedSheet == nil else { return }
    var shortcut = ShortcutDraft.empty
    #if DEBUG
      if UITestHarness.isActive, let prefilled = UITestHarness.prefilledDraftShortcut {
        shortcut = prefilled
      }
    #endif
    presentedSheet = .shortcut(
      ShortcutEditorDraft(purpose: .add, shortcut: shortcut, bundleID: "", mode: .launch)
    )
  }

  private func presentEditShortcut(_ binding: StoredBinding) {
    guard presentedSheet == nil else { return }
    selection = binding.id
    presentedSheet = .shortcut(
      ShortcutEditorDraft(
        purpose: .edit(binding.id),
        shortcut: ShortcutDraft(key: binding.shortcut.key, mods: binding.shortcut.mods),
        bundleID: binding.target.bundleID,
        mode: binding.target.mode
      )
    )
  }

  private func editSelection() {
    guard let selectedBinding else { return }
    presentEditShortcut(selectedBinding)
  }

  private func requestDeletion(_ binding: StoredBinding) {
    selection = binding.id
    pendingDeletion = binding
  }

  private func deleteSelection() {
    guard let selectedBinding else { return }
    requestDeletion(selectedBinding)
  }

  private func delete(_ binding: StoredBinding) {
    pendingDeletion = nil
    Task {
      _ = await model.deleteShortcut(id: binding.id)
      if selection == binding.id {
        selection = nil
      }
    }
  }

  private func finishInitialSetupPresentation() {
    hasPresentedInitialSetup = true
    presentedSheet = nil
  }

  private func sheetDismissed() {
    guard addShortcutAfterSetup else { return }
    addShortcutAfterSetup = false
    presentAddShortcut()
  }

  private func handleURL(_ url: URL) {
    guard url.scheme == SummondBundleIdentifiers.urlScheme else { return }
    switch url.host {
    case "setup":
      presentedSheet = .setup
    case "preferences":
      Task { await model.refresh() }
    case "settings":
      openSettings()
    default:
      break
    }
  }

  private func perform(_ action: HealthAction) {
    switch action {
    case .openSetup:
      presentedSheet = .setup
    case .restartService:
      Task { await model.restartService() }
    case .retryReload:
      Task { await model.retryReload() }
    }
  }
}

private enum MainSheet: Identifiable {
  case setup
  case shortcut(ShortcutEditorDraft)

  var id: String {
    switch self {
    case .setup: "setup"
    case .shortcut(let draft): "shortcut-\(draft.id)"
    }
  }
}

private struct ShortcutEditorSession: View {
  var model: SummondModel
  var onDismiss: () -> Void
  @State private var draft: ShortcutEditorDraft

  init(
    model: SummondModel,
    initialDraft: ShortcutEditorDraft,
    onDismiss: @escaping () -> Void
  ) {
    self.model = model
    self.onDismiss = onDismiss
    _draft = State(initialValue: initialDraft)
  }

  var body: some View {
    ShortcutEditorView(
      draft: $draft,
      applications: model.installedApplications,
      isLoadingApplications: model.installedAppsLoading,
      validationMessages: model.validationIssues(for: draft).map(\.message),
      loadApplications: model.loadInstalledApplicationsIfNeeded,
      resolveApplication: model.identity,
      recordShortcut: model.recordShortcut,
      onSave: save,
      onCancel: onDismiss
    )
  }

  private func save(_ draft: ShortcutEditorDraft) async -> String? {
    switch await model.saveShortcut(draft) {
    case .saved, .savedButReloadFailed:
      return nil
    case .failed(let message):
      return message
    case .invalid(let issues):
      return issues.map(\.message).joined(separator: "\n")
    }
  }
}

struct ShortcutCommands {
  var add: () -> Void
  var edit: () -> Void
  var delete: () -> Void
  var canEdit: Bool
  var canDelete: Bool
}

private struct ShortcutCommandsKey: FocusedValueKey {
  typealias Value = ShortcutCommands
}

extension FocusedValues {
  var shortcutCommands: ShortcutCommands? {
    get { self[ShortcutCommandsKey.self] }
    set { self[ShortcutCommandsKey.self] = newValue }
  }
}

private enum HealthAction {
  case openSetup
  case restartService
  case retryReload
}

private struct SystemHealthBanner: View {
  var notice: HealthNotice
  var action: (HealthAction) -> Void

  var body: some View {
    NoticeBanner(
      symbol: notice.symbol,
      color: notice.color,
      title: notice.title,
      message: notice.message,
      actionTitle: notice.actionTitle,
      action: notice.action.map { value in { action(value) } }
    )
    .accessibilityIdentifier("health.notice")
  }
}

private struct NoticeBanner: View {
  var symbol: String
  var color: Color
  var title: String
  var message: String
  var actionTitle: String?
  var actionIdentifier: String
  var action: (() -> Void)?

  init(
    symbol: String,
    color: Color,
    title: String,
    message: String,
    actionTitle: String? = nil,
    actionIdentifier: String = "notice.actionButton",
    action: (() -> Void)? = nil
  ) {
    self.symbol = symbol
    self.color = color
    self.title = title
    self.message = message
    self.actionTitle = actionTitle
    self.actionIdentifier = actionIdentifier
    self.action = action
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: symbol)
        .foregroundStyle(color)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.callout.weight(.semibold))
        Text(message)
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      Spacer()
      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .buttonStyle(.borderedProminent)
          .tint(color)
          .accessibilityIdentifier(actionIdentifier)
      }
    }
    .padding(12)
    .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .contain)
  }
}

private struct HealthStatusStrip: View {
  var health: SystemHealth

  var body: some View {
    HStack(spacing: 7) {
      Circle()
        .fill(color)
        .frame(width: 7, height: 7)
      Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("health.status")
  }

  private var color: Color {
    if case .ready = health { return .green }
    return .orange
  }

  private var text: String {
    switch health {
    case .ready(let count):
      return "Active — \(count) \(count == 1 ? "shortcut" : "shortcuts")"
    case .setupRequired:
      return "Setup required"
    case .degraded:
      return "Shortcuts need attention"
    }
  }
}

private struct HealthNotice {
  let symbol = "exclamationmark.triangle.fill"
  let color = Color.orange
  var title: String
  var message: String
  var actionTitle: String?
  var action: HealthAction?

  init(setup requirement: SetupRequirement) {
    title = "Finish Setting Up Summond"
    message = requirement.message
    actionTitle = "Open Setup"
    action = .openSetup
  }

  init(issue: SystemIssue) {
    title = issue.title
    message = issue.message
    switch issue {
    case .agentUnavailable, .shortcutListenerInactive:
      actionTitle = "Restart Service"
      action = .restartService
    case .reloadFailed:
      actionTitle = "Retry Reload"
      action = .retryReload
    case .configurationUnavailable, .configurationCorrupt, .configurationInvalid,
      .unresolvedApplications, .shortcutRegistrationFailures:
      break
    }
  }
}

extension SetupRequirement {
  fileprivate var message: String {
    switch self {
    case .backgroundServiceApprovalRequired:
      "Approve Summond under System Settings → General → Login Items."
    case .backgroundServiceNotRegistered:
      "Enable the background service and grant the required permissions."
    case .backgroundServiceNotFound:
      "The background service could not be found. Try enabling it again."
    case .accessibilityPermission:
      "Grant Summond Accessibility permission so New Window and Move Here shortcuts can manage windows."
    }
  }
}

extension SystemIssue {
  fileprivate var title: String {
    switch self {
    case .agentUnavailable: "Background Service Is Not Responding"
    case .configurationUnavailable: "Configuration Is Unavailable"
    case .configurationCorrupt, .configurationInvalid: "Configuration Needs Attention"
    case .unresolvedApplications: "Some Applications Are Missing"
    case .shortcutRegistrationFailures: "Some Shortcuts Are Not Registered"
    case .shortcutListenerInactive: "Shortcut Listener Is Inactive"
    case .reloadFailed: "Changes Saved, Reload Failed"
    }
  }

  fileprivate var message: String {
    switch self {
    case .agentUnavailable:
      return "Restart the background service to resume shortcuts."
    case .configurationUnavailable(let details):
      return details
    case .configurationCorrupt(let details):
      return details ?? "The agent could not read the saved configuration."
    case .configurationInvalid(let details):
      return details ?? "The agent rejected the saved configuration."
    case .unresolvedApplications(let bundleIDs):
      let count = bundleIDs.count
      let noun = count == 1 ? "application is" : "applications are"
      return "\(count) configured \(noun) not installed."
    case .shortcutRegistrationFailures(let shortcuts):
      return "macOS rejected these shortcuts: \(shortcuts.joined(separator: ", ")). "
        + "They may conflict with another app."
    case .shortcutListenerInactive:
      return "The global shortcut listener stopped. Restart the service to resume it."
    case .reloadFailed(let details):
      return details
    }
  }
}
