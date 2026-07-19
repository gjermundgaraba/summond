import SummondCore
import SwiftUI

struct SettingsView: View {
  var model: SummondModel

  @Environment(\.openURL) private var openURL
  @State private var confirmsServiceDisable = false

  var body: some View {
    TabView {
      generalTab
        .tabItem {
          Label("General", systemImage: "gearshape")
        }

      diagnosticsTab
        .tabItem {
          Label("Diagnostics", systemImage: "stethoscope")
        }
    }
    .frame(width: 560, height: 470)
    .scenePadding()
    .task {
      await model.refresh()
    }
    .alert("Disable Background Service?", isPresented: $confirmsServiceDisable) {
      Button("Cancel", role: .cancel) {}
      Button("Disable", role: .destructive) {
        Task { await model.disableService() }
      }
    } message: {
      Text("Global shortcuts will stop working until you enable the service again.")
    }
  }

  private var generalTab: some View {
    Form {
      Section("Shortcuts") {
        Toggle(
          "Verbose logging",
          isOn: Binding(
            get: { model.configuration.verboseLogging },
            set: { isEnabled in
              Task { await model.setVerboseLogging(isEnabled) }
            }
          )
        )
        .disabled(model.isSaving)
        .accessibilityIdentifier("settings.verboseLogging")

        Text("Records additional shortcut and window-matching details for troubleshooting.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Menu Bar") {
        Toggle(
          "Show menu bar icon",
          isOn: Binding(
            get: { model.isStatusItemShown },
            set: { isShown in
              Task { await model.setStatusItemShown(isShown) }
            }
          )
        )
        .disabled(model.isStatusItemBusy)

        if model.isStatusItemBusy {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text("Updating menu bar…")
              .foregroundStyle(.secondary)
          }
        } else if let error = model.statusItemError {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        } else if model.statusItemStatus == .requiresApproval {
          Text("Approve Summond in System Settings, General, Login Items.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }

      Section("Setup") {
        LabeledContent("Background service", value: model.serviceStatus.settingsTitle)

        Button("Open Setup Assistant…") {
          if let url = URL(string: "summond://setup") {
            openURL(url)
          }
        }

        if model.serviceStatus == .requiresApproval {
          Button("Open Login Items…") {
            model.openLoginItemsSettings()
          }
        }
      }
    }
    .formStyle(.grouped)
  }

  private var diagnosticsTab: some View {
    Form {
      Section("System Health") {
        LabeledContent("Status") {
          Label(model.health.settingsTitle, systemImage: model.health.settingsSymbol)
            .foregroundStyle(model.health.settingsColor)
        }

        if let detail = model.health.settingsDetail {
          Text(detail)
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }

        Button("Refresh Status") {
          Task { await model.refresh() }
        }
      }

      Section("Agent") {
        if let status = model.agentStatus {
          LabeledContent("Version", value: status.agentVersion)
          LabeledContent(
            "Accessibility", value: status.accessibilityGranted ? "Granted" : "Missing")
          LabeledContent(
            "Input Monitoring", value: status.inputMonitoringGranted ? "Granted" : "Missing")
          LabeledContent("Shortcut listener", value: status.tapActive ? "Active" : "Inactive")
          LabeledContent("Configuration", value: status.configState.settingsTitle)
          LabeledContent("Shortcuts", value: "\(status.bindingCount)")

          if let reason = status.tapFailureReason {
            LabeledContent("Listener issue", value: reason.settingsTitle)
          }

          if !status.unresolvedBundleIDs.isEmpty {
            LabeledContent("Apps not installed") {
              Text(status.unresolvedBundleIDs.joined(separator: "\n"))
                .textSelection(.enabled)
            }
          }

          if let error = status.lastReloadError {
            LabeledContent("Agent reload error") {
              Text(error)
                .textSelection(.enabled)
            }
          }
        } else {
          Text("Agent status is unavailable.")
            .foregroundStyle(.secondary)
        }

        if let error = model.serviceError {
          LabeledContent("Service error") {
            Text(error)
              .foregroundStyle(.red)
              .textSelection(.enabled)
          }
        }

        if let error = model.reloadError {
          LabeledContent("Reload error") {
            Text(error)
              .foregroundStyle(.red)
              .textSelection(.enabled)
          }

          Button("Retry Reload") {
            Task { await model.retryReload() }
          }
        }
      }

      Section {
        Button("Disable Background Service…", role: .destructive) {
          confirmsServiceDisable = true
        }
        .disabled(!model.serviceStatus.canUnregister || model.isServiceBusy)
      } footer: {
        Text("Disabling the service stops every global shortcut.")
      }
    }
    .formStyle(.grouped)
  }
}

extension ServiceRegistrationStatus {
  fileprivate var settingsTitle: String {
    switch self {
    case .enabled: "Enabled"
    case .requiresApproval: "Requires Approval"
    case .notRegistered: "Not Registered"
    case .notFound: "Not Found"
    }
  }

  fileprivate var canUnregister: Bool {
    switch self {
    case .enabled, .requiresApproval:
      true
    case .notRegistered, .notFound:
      false
    }
  }
}

extension SystemHealth {
  fileprivate var settingsTitle: String {
    switch self {
    case .ready:
      "Ready"
    case .setupRequired:
      "Setup Required"
    case .degraded:
      "Needs Attention"
    }
  }

  fileprivate var settingsSymbol: String {
    switch self {
    case .ready: "checkmark.circle.fill"
    case .setupRequired: "gearshape.2.fill"
    case .degraded: "exclamationmark.triangle.fill"
    }
  }

  fileprivate var settingsColor: Color {
    switch self {
    case .ready: .green
    case .setupRequired: .orange
    case .degraded: .orange
    }
  }

  fileprivate var settingsDetail: String? {
    switch self {
    case .ready(let activeShortcuts):
      let noun = activeShortcuts == 1 ? "shortcut is" : "shortcuts are"
      return "\(activeShortcuts) \(noun) active."
    case .setupRequired(let requirement):
      switch requirement {
      case .backgroundServiceApprovalRequired:
        return "Approve Summond in Login Items."
      case .backgroundServiceNotRegistered:
        return "The background service is disabled."
      case .backgroundServiceNotFound:
        return "The background service could not be found."
      case .accessibilityPermission:
        return "Accessibility permission is required."
      case .inputMonitoringPermission:
        return "Input Monitoring permission is required."
      }
    case .degraded(let issue):
      switch issue {
      case .agentUnavailable:
        return "The background agent is not responding."
      case .configurationUnavailable(let details):
        return details
      case .configurationCorrupt(let details):
        return details ?? "The saved configuration could not be read."
      case .configurationInvalid(let details):
        return details ?? "The saved configuration is invalid."
      case .unresolvedApplications(let bundleIDs):
        let count = bundleIDs.count
        let noun = count == 1 ? "application is" : "applications are"
        return "\(count) configured \(noun) not installed."
      case .eventTapFailure(let reason):
        return reason.settingsTitle
      case .eventTapInactive:
        return "The global shortcut listener is inactive."
      case .reloadFailed(let details):
        return details
      }
    }
  }
}

extension AgentConfigurationState {
  fileprivate var settingsTitle: String {
    switch self {
    case .ok: "Ready"
    case .fresh: "New"
    case .corrupt: "Corrupt"
    case .invalid: "Invalid"
    }
  }
}

extension EventTapFailureReason {
  fileprivate var settingsTitle: String {
    switch self {
    case .accessibilityDenied: "Accessibility permission is missing."
    case .inputMonitoringDenied: "Input Monitoring permission is missing."
    case .installationFailed: "The shortcut listener could not start."
    case .disabledByTimeout: "The shortcut listener timed out."
    case .disabledByUserInput: "macOS disabled the shortcut listener."
    case .restartLoopDetected: "The shortcut listener paused after repeated restarts."
    }
  }
}
