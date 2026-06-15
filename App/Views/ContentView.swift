import AppKit
import KeybinddCore
import SwiftUI

struct ContentView: View {
  var serviceManager: ServiceManager
  var preferencesModel: PreferencesViewModel
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
  @State private var selection: StoredBinding.ID?
  @State private var showResetConfirmation = false
  @State private var isOnboardingPresented = false
  @State private var dismissedOnboardingThisSession = false

  var body: some View {
    VStack(spacing: 0) {
      if let banner = preferencesModel.banner {
        PreferencesBannerView(
          banner: banner,
          resetAction: resetAction(for: preferencesModel.loadState)
        )
        .padding([.horizontal, .top], 16)
      }

      if shouldShowSetupBanner {
        SetupNeededBanner {
          dismissedOnboardingThisSession = false
          isOnboardingPresented = true
        }
        .padding([.horizontal, .top], 16)
      }

      BindingListView(
        model: preferencesModel,
        selection: $selection,
        addAction: { preferencesModel.beginAdding() }
      )
      .padding(.horizontal, 16)
      .padding(.top, preferencesModel.banner == nil && !shouldShowSetupBanner ? 16 : 10)
      .padding(.bottom, 16)
    }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button {
          preferencesModel.beginAdding()
        } label: {
          Label("Add Shortcut", systemImage: "plus")
        }
        .help("Add shortcut")
        .accessibilityIdentifier("toolbar.addShortcut")

        Button {
          deleteSelection()
        } label: {
          Label("Delete", systemImage: "trash")
        }
        .help("Delete selected shortcut")
        .disabled(selection == nil || preferencesModel.isSaving)
        .accessibilityIdentifier("toolbar.deleteShortcut")

        Button {
          Task { await serviceManager.reloadAgentConfiguration() }
        } label: {
          Label("Reload", systemImage: "arrow.clockwise")
        }
        .help("Reload bindings in the background service")
      }

      if serviceManager.needsSetup {
        ToolbarItem(placement: .status) {
          Button {
            dismissedOnboardingThisSession = false
            isOnboardingPresented = true
          } label: {
            Label("Finish Setup", systemImage: "exclamationmark.triangle.fill")
          }
          .buttonStyle(.bordered)
          .tint(.orange)
          .help("Finish required setup")
        }
      }
    }
    .sheet(isPresented: $isOnboardingPresented, onDismiss: onboardingDismissed) {
      OnboardingView(
        serviceManager: serviceManager,
        hasCompletedOnboarding: $hasCompletedOnboarding,
        onAddFirstShortcut: {
          preferencesModel.beginAdding()
        }
      )
      .frame(width: 520, height: 460)
    }
    .confirmationDialog(
      "Reset configuration?",
      isPresented: $showResetConfirmation
    ) {
      Button("Reset to Empty Configuration", role: .destructive) {
        Task {
          await preferencesModel.resetCorruptConfiguration()
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This writes a valid empty configuration. The corrupt data will not be recovered.")
    }
    .task {
      await serviceManager.refresh()
      presentOnboardingIfNeeded()
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else {
        return
      }
      Task {
        await serviceManager.refresh()
        presentOnboardingIfNeeded()
      }
    }
    .onChange(of: serviceManager.setupState) { _, _ in
      presentOnboardingIfNeeded()
    }
    .onChange(of: serviceManager.setupRequestID) { _, _ in
      dismissedOnboardingThisSession = false
      isOnboardingPresented = true
    }
    .onChange(of: preferencesModel.editorPresentationID) { _, _ in
      #if DEBUG
        // The UI-test harness hosts the editor in its own AppKit window; opening
        // the SwiftUI scene too would create a duplicate editor.
        if UITestHarness.isActive { return }
      #endif
      if preferencesModel.editorDraft != nil {
        openWindow(id: "binding-editor")
        NSApp.activate()
      }
    }
    .onChange(of: preferencesModel.editorDraft == nil) { _, isNil in
      #if DEBUG
        if UITestHarness.isActive { return }
      #endif
      if isNil {
        dismissWindow(id: "binding-editor")
      }
    }
    .focusedValue(
      \.preferencesCommands,
      PreferencesCommands(
        add: { preferencesModel.beginAdding() },
        edit: { editSelection() },
        delete: { deleteSelection() },
        reload: { Task { await serviceManager.reloadAgentConfiguration() } },
        canEdit: selection != nil,
        canDelete: selection != nil && !preferencesModel.isSaving,
        canReload: true
      )
    )
  }

  private var shouldShowSetupBanner: Bool {
    hasCompletedOnboarding && serviceManager.needsSetup && !isOnboardingPresented
  }

  private func presentOnboardingIfNeeded() {
    guard !isOnboardingPresented else {
      return
    }

    if (!hasCompletedOnboarding && !dismissedOnboardingThisSession)
      || (serviceManager.needsSetup && !dismissedOnboardingThisSession)
    {
      isOnboardingPresented = true
    }
  }

  private func onboardingDismissed() {
    if serviceManager.setupState.hardRequirementsSatisfied {
      hasCompletedOnboarding = true
    } else {
      dismissedOnboardingThisSession = true
    }
  }

  private func deleteSelection() {
    guard let selection else {
      return
    }
    Task {
      await preferencesModel.deleteBinding(id: selection)
      self.selection = nil
    }
  }

  private func editSelection() {
    guard
      let selection,
      let binding = preferencesModel.draft.bindings.first(where: { $0.id == selection })
    else {
      return
    }

    preferencesModel.beginEditing(binding)
  }

  private func resetAction(for loadState: PreferencesViewModel.LoadState) -> (() -> Void)? {
    guard case .corrupt = loadState else {
      return nil
    }
    return {
      showResetConfirmation = true
    }
  }
}

struct PreferencesCommands {
  var add: () -> Void
  var edit: () -> Void
  var delete: () -> Void
  var reload: () -> Void
  var canEdit: Bool
  var canDelete: Bool
  var canReload: Bool
}

private struct PreferencesCommandsKey: FocusedValueKey {
  typealias Value = PreferencesCommands
}

extension FocusedValues {
  var preferencesCommands: PreferencesCommands? {
    get { self[PreferencesCommandsKey.self] }
    set { self[PreferencesCommandsKey.self] = newValue }
  }
}

private struct SetupNeededBanner: View {
  var action: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text("Setup needed")
          .font(.callout.weight(.semibold))
        Text(
          "Keybindd needs its background service, and KeybinddAgent needs Accessibility and Input Monitoring, to run shortcuts."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Open Setup") {
        action()
      }
      .buttonStyle(.borderedProminent)
      .tint(.orange)
    }
    .padding(12)
    .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
  }
}
