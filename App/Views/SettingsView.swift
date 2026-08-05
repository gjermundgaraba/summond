import SummondCore
import SwiftUI

struct SettingsView: View {
  var model: SummondModel
  private let uninstallApplicationManager: any UninstallApplicationManaging

  @Environment(\.openURL) private var openURL
  @State private var showsUninstallPreparation = false

  init(
    model: SummondModel,
    uninstallApplicationManager: any UninstallApplicationManaging = UninstallApplicationManager()
  ) {
    self.model = model
    self.uninstallApplicationManager = uninstallApplicationManager
  }

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
    .sheet(isPresented: $showsUninstallPreparation) {
      PrepareToUninstallView(
        model: model,
        applicationManager: uninstallApplicationManager
      )
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

        if let error = model.configurationError ?? model.reloadError {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
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
        .disabled(model.isStatusItemBusy || model.isPreparingToUninstall)

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

      Section("Uninstall") {
        Button("Prepare to Uninstall…", role: .destructive) {
          model.clearUninstallPreparationError()
          showsUninstallPreparation = true
        }
        .disabled(
          model.isPreparingToUninstall || model.isServiceBusy || model.isStatusItemBusy
        )
        .accessibilityIdentifier("settings.prepareToUninstall")

        Text("Stops Summond’s background components before you move the app to the Trash.")
          .font(.caption)
          .foregroundStyle(.secondary)
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
          LabeledContent("Shortcut listener", value: status.shortcutsActive ? "Active" : "Inactive")
          LabeledContent("Configuration", value: status.configState.settingsTitle)
          LabeledContent("Shortcuts", value: "\(status.bindingCount)")

          if !status.failedShortcuts.isEmpty {
            LabeledContent("Shortcuts not registered") {
              Text(status.failedShortcuts.joined(separator: "\n"))
                .textSelection(.enabled)
            }
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

        if let error = model.permissionError {
          LabeledContent("Permission request error") {
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
      case .shortcutRegistrationFailures(let shortcuts):
        let count = shortcuts.count
        let noun = count == 1 ? "shortcut" : "shortcuts"
        return "\(count) \(noun) could not be registered with macOS."
      case .shortcutListenerInactive:
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
    case .unavailable: "Unavailable"
    case .corrupt: "Corrupt"
    case .invalid: "Invalid"
    }
  }
}
