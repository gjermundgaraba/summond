import SummondCore
import SwiftUI

struct OnboardingView: View {
  var serviceManager: ServiceManager
  @Binding var hasCompletedOnboarding: Bool
  var showsFirstShortcutAction: Bool
  var onAddFirstShortcut: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var step: OnboardingStep = .welcome

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        ProgressView(value: Double(step.rawValue), total: Double(OnboardingStep.done.rawValue))
          .controlSize(.small)

        Group {
          switch step {
          case .welcome:
            welcomeStep
          case .backgroundService:
            backgroundServiceStep
          case .accessibility:
            accessibilityStep
          case .inputMonitoring:
            inputMonitoringStep
          case .done:
            doneStep
          }
        }
        .frame(maxWidth: .infinity, minHeight: 330, alignment: .topLeading)
      }
      .padding(28)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .task {
      if hasCompletedOnboarding, let unmetStep = serviceManager.setupState.firstUnmetOnboardingStep
      {
        step = unmetStep
      }
      await serviceManager.refresh()
      advanceIfReady()

      while !Task.isCancelled {
        do {
          try await Task.sleep(nanoseconds: 1_000_000_000)
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        await serviceManager.refresh()
        guard !Task.isCancelled else { return }
        advanceIfReady()
      }
    }
  }

  private var welcomeStep: some View {
    VStack(alignment: .leading, spacing: 18) {
      stepIcon("keyboard.badge.eye")
      Text("Welcome to Summond")
        .font(.title.weight(.semibold))
      Text(
        "A small background agent turns global keyboard shortcuts into app actions. macOS needs two approvals before it can listen for those shortcuts."
      )
      .foregroundStyle(.secondary)
      Spacer()
      Button("Get Started") {
        step = .backgroundService
        advanceIfReady()
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .accessibilityIdentifier("onboarding.getStartedButton")
    }
  }

  private var backgroundServiceStep: some View {
    VStack(alignment: .leading, spacing: 16) {
      stepIcon(serviceManager.setupState.serviceReady ? "checkmark.circle.fill" : "gear.badge")
        .foregroundStyle(serviceManager.setupState.serviceReady ? .green : .accentColor)
      Text("Background Service")
        .font(.title2.weight(.semibold))

      switch serviceManager.serviceStatus {
      case .enabled:
        if serviceManager.setupState.agentReachable {
          Label("The background service is enabled.", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        } else {
          Text("The background service is enabled, but Summond can't reach its agent.")
            .foregroundStyle(.secondary)
          if let error = serviceManager.lastError {
            Text(error)
              .font(.callout)
              .foregroundStyle(.red)
              .textSelection(.enabled)
          }
          Button("Restart Service") {
            Task { await serviceManager.restartServiceRegistration() }
          }
          .buttonStyle(.borderedProminent)
          .disabled(serviceManager.isServiceBusy)
        }
      case .requiresApproval:
        Text("Approve Summond in Login Items so macOS can start the background agent.")
          .foregroundStyle(.secondary)
        Button("Open Login Items") {
          serviceManager.openLoginItemsSettings()
        }
        .buttonStyle(.borderedProminent)
      case .notRegistered, .notFound:
        if let error = serviceManager.lastRegistrationError {
          Text("Couldn't register the background service: \(error)")
            .font(.callout)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        } else {
          Text("Enable the background service so macOS can run Summond's shortcut agent.")
            .foregroundStyle(.secondary)
        }

        Button(serviceManager.lastRegistrationError == nil ? "Enable Service" : "Try Again") {
          Task { await serviceManager.register() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(serviceManager.isServiceBusy)
      }

      Spacer()
    }
  }

  private var accessibilityStep: some View {
    VStack(alignment: .leading, spacing: 16) {
      stepIcon(
        serviceManager.setupState.accessibilityGranted
          ? "checkmark.circle.fill" : "hand.raised.fill"
      )
      .foregroundStyle(serviceManager.setupState.accessibilityGranted ? .green : .accentColor)
      Text("Accessibility")
        .font(.title2.weight(.semibold))
      Text(
        "Global key interception runs in the background agent. Enable SummondAgent in Privacy & Security, Accessibility."
      )
      .foregroundStyle(.secondary)

      if serviceManager.setupState.accessibilityGranted {
        Label("Accessibility permission is granted.", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
      } else {
        Button("Open Accessibility Settings") {
          serviceManager.requestAccessibilitySetup()
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("onboarding.openAccessibilitySettingsButton")

        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Waiting for permission — this continues automatically once granted.")
            .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
      }

      Spacer()
    }
  }

  private var inputMonitoringStep: some View {
    VStack(alignment: .leading, spacing: 16) {
      stepIcon(
        serviceManager.setupState.inputMonitoringGranted
          ? "checkmark.circle.fill" : "keyboard.badge.eye"
      )
      .foregroundStyle(serviceManager.setupState.inputMonitoringGranted ? .green : .accentColor)
      Text("Input Monitoring")
        .font(.title2.weight(.semibold))
      Text(
        "macOS also needs Input Monitoring permission for SummondAgent before it can receive global shortcut key presses."
      )
      .foregroundStyle(.secondary)

      if serviceManager.setupState.inputMonitoringGranted {
        Label("Input Monitoring permission is granted.", systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
      } else {
        Button("Open Input Monitoring Settings") {
          serviceManager.requestInputMonitoringSetup()
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("onboarding.openInputMonitoringSettingsButton")

        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Waiting for permission — this continues automatically once granted.")
            .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
      }

      Spacer()
    }
  }

  private var doneStep: some View {
    VStack(alignment: .leading, spacing: 18) {
      stepIcon("checkmark.circle.fill")
        .foregroundStyle(.green)
      Text("You're all set")
        .font(.title.weight(.semibold))
      Text("Summond is ready to run your shortcuts.")
        .foregroundStyle(.secondary)
      Spacer()
      HStack {
        Button("Done") {
          completeAndDismiss(addFirstShortcut: false)
        }
        .keyboardShortcut(.cancelAction)

        Spacer()

        if showsFirstShortcutAction {
          Button("Add Your First Shortcut") {
            completeAndDismiss(addFirstShortcut: true)
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
        }
      }
    }
  }

  private func stepIcon(_ systemName: String) -> some View {
    Image(systemName: systemName)
      .font(.system(size: 42, weight: .semibold))
      .symbolRenderingMode(.hierarchical)
  }

  private func advanceIfReady() {
    let resolved = serviceManager.setupState.resolvedStep(from: step)
    if resolved != step {
      step = resolved
    }
  }

  private func completeAndDismiss(addFirstShortcut: Bool) {
    hasCompletedOnboarding = true
    dismiss()
    if addFirstShortcut {
      onAddFirstShortcut()
    }
  }
}
