import PermissionFlow
import SummondCore
import SwiftUI

struct SetupAssistantView: View {
  var model: SummondModel
  var showsFirstShortcutAction: Bool
  var onDismiss: () -> Void
  var onAddFirstShortcut: () -> Void

  // PermissionFlow's status providers inspect this UI process, but the
  // permissions belong to the embedded SummondAgent helper. Keep this
  // controller local to the sheet and continue to render agentStatus instead.
  @StateObject private var permissionFlowController = PermissionFlowController(
    configuration: .init(promptForAccessibilityTrust: false)
  )

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header

      VStack(spacing: 12) {
        backgroundServiceRow
        permissionRow(
          title: "Accessibility",
          explanation:
            "Required so Summond can direct application windows.",
          systemImage: "hand.raised.fill",
          isGranted: accessibilityGranted,
          actionTitle: "Open Settings…",
          action: startAccessibilitySetup,
          accessibilityIdentifier: "setup.openAccessibilitySettingsButton"
        )
        if let error = model.permissionError {
          Text("Permission request failed: \(error)")
            .font(.callout)
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .accessibilityIdentifier("setup.permissionError")
        }
      }
      .padding(.horizontal, 28)
      .padding(.bottom, 24)

      Divider()

      footer
        .padding(20)
    }
    .frame(width: 600)
    .fixedSize(horizontal: false, vertical: true)
    .onDisappear {
      permissionFlowController.closePanel()
    }
    .task {
      while !Task.isCancelled, !accessibilityGranted {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return }
        await model.refresh()
      }
    }
    .onChange(of: accessibilityGranted) { _, isGranted in
      guard isGranted else { return }
      permissionFlowController.closePanel(returnToPreviousApp: true)
    }
  }

  private func startAccessibilitySetup() {
    Task { await model.requestAccessibilitySetup() }

    #if DEBUG
      if UITestHarness.isActive, !UITestHarness.allowsSystemPermissionFlow { return }
    #endif

    guard let agentAppURL = PermissionFlowHelperAppLocator.bundledAgentAppURL() else {
      model.openAccessibilitySettings()
      return
    }

    permissionFlowController.authorize(pane: .accessibility, suggestedAppURLs: [agentAppURL])
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 18) {
      Image(systemName: setupRequirementsComplete ? "checkmark.circle.fill" : "keyboard.badge.eye")
        .font(.system(size: 42, weight: .semibold))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(setupRequirementsComplete ? Color.green : Color.accentColor)
        .contentTransition(.symbolEffect(.replace))

      VStack(alignment: .leading, spacing: 6) {
        Text(setupRequirementsComplete ? "Setup complete" : "Set up Summond")
          .font(.title.weight(.semibold))
        Text(
          setupRequirementsComplete
            ? "Summond has the macOS access it needs."
            : "Complete these two macOS requirements to use Summond."
        )
        .foregroundStyle(.secondary)
      }
    }
    .padding(28)
  }

  private var backgroundServiceRow: some View {
    SetupChecklistRow(
      title: "Background Service",
      explanation: backgroundServiceExplanation,
      systemImage: "gearshape.2.fill",
      state: backgroundServiceState
    ) {
      switch model.serviceStatus {
      case .enabled:
        if model.agentStatus == nil {
          Button("Restart Service") {
            Task { await model.restartService() }
          }
          .disabled(model.isServiceBusy || model.isPreparingToUninstall)
        }
      case .requiresApproval:
        Button("Open Login Items…") {
          model.openLoginItemsSettings()
        }
      case .notRegistered, .notFound:
        Button(model.serviceError == nil ? "Enable Service" : "Try Again") {
          Task { await model.enableService() }
        }
        .disabled(model.isServiceBusy || model.isPreparingToUninstall)
      }
    }
  }

  private func permissionRow(
    title: String,
    explanation: String,
    systemImage: String,
    isGranted: Bool,
    actionTitle: String,
    action: @escaping () -> Void,
    accessibilityIdentifier: String
  ) -> some View {
    SetupChecklistRow(
      title: title,
      explanation: explanation,
      systemImage: systemImage,
      state: isGranted ? .complete : .required
    ) {
      if !isGranted {
        Button(actionTitle, action: action)
          .accessibilityIdentifier(accessibilityIdentifier)
      }
    }
  }

  private var footer: some View {
    HStack {
      Button("Set Up Later") {
        onDismiss()
      }
      .keyboardShortcut(.cancelAction)
      .accessibilityIdentifier("setup.setUpLaterButton")

      Spacer()

      if setupRequirementsComplete {
        if showsFirstShortcutAction {
          Button("Add Your First Shortcut") {
            onDismiss()
            onAddFirstShortcut()
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
        } else {
          Button("Done") {
            onDismiss()
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
        }
      }
    }
  }

  private var setupRequirementsComplete: Bool {
    model.serviceStatus == .enabled
      && model.agentStatus != nil
      && accessibilityGranted
  }

  private var accessibilityGranted: Bool {
    model.agentStatus?.accessibilityGranted == true
  }

  private var backgroundServiceState: SetupChecklistState {
    guard model.serviceStatus == .enabled else { return .required }
    return model.agentStatus == nil ? .attention : .complete
  }

  private var backgroundServiceExplanation: String {
    switch model.serviceStatus {
    case .enabled:
      if model.agentStatus == nil {
        return model.serviceError ?? model.agentConnectionError
          ?? "The service is enabled but isn't responding."
      }
      return "Runs your shortcuts even when the Summond window is closed."
    case .requiresApproval:
      return "Approve Summond in System Settings, General, Login Items."
    case .notRegistered:
      return model.serviceError ?? "Enable Summond's background service."
    case .notFound:
      return model.serviceError ?? "The background service could not be found."
    }
  }
}

private enum SetupChecklistState {
  case complete
  case required
  case attention

  var icon: String {
    switch self {
    case .complete: "checkmark.circle.fill"
    case .required: "circle"
    case .attention: "exclamationmark.circle.fill"
    }
  }

  var color: Color {
    switch self {
    case .complete: .green
    case .required: .secondary
    case .attention: .orange
    }
  }
}

private struct SetupChecklistRow<Actions: View>: View {
  var title: String
  var explanation: String
  var systemImage: String
  var state: SetupChecklistState
  @ViewBuilder var actions: () -> Actions

  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      Image(systemName: systemImage)
        .font(.title2)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(Color.accentColor)
        .frame(width: 28)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.headline)
        Text(explanation)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }

      Spacer(minLength: 12)
      actions()

      Image(systemName: state.icon)
        .font(.title3)
        .foregroundStyle(state.color)
        .contentTransition(.symbolEffect(.replace))
        .accessibilityLabel(state == .complete ? "Complete" : "Action required")
    }
    .padding(16)
    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
  }
}
