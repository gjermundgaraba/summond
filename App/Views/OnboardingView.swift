import SummondCore
import SwiftUI

struct SetupAssistantView: View {
  var model: SummondModel
  var showsFirstShortcutAction: Bool
  var onDismiss: () -> Void
  var onAddFirstShortcut: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header

      VStack(spacing: 12) {
        backgroundServiceRow
        permissionRow(
          title: "Accessibility",
          explanation: "Allows Summond to direct application windows.",
          systemImage: "hand.raised.fill",
          isGranted: accessibilityGranted,
          actionTitle: "Open Settings…",
          action: model.requestAccessibilitySetup,
          accessibilityIdentifier: "setup.openAccessibilitySettingsButton"
        )
        permissionRow(
          title: "Input Monitoring",
          explanation: "Allows Summond to receive your global shortcuts.",
          systemImage: "keyboard.badge.eye",
          isGranted: inputMonitoringGranted,
          actionTitle: "Open Settings…",
          action: model.requestInputMonitoringSetup,
          accessibilityIdentifier: "setup.openInputMonitoringSettingsButton"
        )
      }
      .padding(.horizontal, 28)
      .padding(.bottom, 24)

      Divider()

      footer
        .padding(20)
    }
    .frame(width: 600)
    .fixedSize(horizontal: false, vertical: true)
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
            : "Complete these three macOS requirements to use global shortcuts."
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
          .disabled(model.isServiceBusy)
        }
      case .requiresApproval:
        Button("Open Login Items…") {
          model.openLoginItemsSettings()
        }
      case .notRegistered, .notFound:
        Button(model.serviceError == nil ? "Enable Service" : "Try Again") {
          Task { await model.enableService() }
        }
        .disabled(model.isServiceBusy)
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
      && inputMonitoringGranted
  }

  private var accessibilityGranted: Bool {
    model.agentStatus?.accessibilityGranted == true
  }

  private var inputMonitoringGranted: Bool {
    model.agentStatus?.inputMonitoringGranted == true
  }

  private var backgroundServiceState: SetupChecklistState {
    guard model.serviceStatus == .enabled else { return .required }
    return model.agentStatus == nil ? .attention : .complete
  }

  private var backgroundServiceExplanation: String {
    switch model.serviceStatus {
    case .enabled:
      if model.agentStatus == nil {
        return model.serviceError ?? "The service is enabled but isn't responding."
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
