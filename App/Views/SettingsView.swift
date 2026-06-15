import KeybinddCore
import SwiftUI

struct SettingsView: View {
  var serviceManager: ServiceManager
  var preferencesModel: PreferencesViewModel

  var body: some View {
    Form {
      Section("General") {
        Toggle(
          "Verbose logging",
          isOn: Binding(
            get: { preferencesModel.draft.verboseLogging },
            set: { isEnabled in
              Task {
                await preferencesModel.setVerboseLogging(isEnabled)
              }
            }
          )
        )
        .disabled(preferencesModel.isSaving)
        .accessibilityIdentifier("settings.verboseLogging")

        Toggle(
          "Show menu bar icon",
          isOn: Binding(
            get: { serviceManager.isStatusItemShown },
            set: { isShown in
              Task {
                await serviceManager.setStatusItemShown(isShown)
              }
            }
          )
        )
        .disabled(serviceManager.isStatusItemBusy)
      }

      Section("Advanced") {
        LabeledContent("Background service", value: serviceManager.servicePresentation.title)
        if serviceManager.serviceStatus == .requiresApproval {
          Button("Open Login Items") {
            serviceManager.openLoginItemsSettings()
          }
        }

        Button("Re-run Setup") {
          serviceManager.requestOnboarding()
        }

        Button("Disable Background Service", role: .destructive) {
          Task {
            await serviceManager.unregister()
          }
        }
        .disabled(!serviceManager.servicePresentation.canUnregister || serviceManager.isServiceBusy)
      }

      Section("Diagnostics") {
        Button("Refresh Status") {
          Task {
            await serviceManager.refresh()
          }
        }

        if let status = serviceManager.agentStatus {
          LabeledContent("Agent version", value: status.agentVersion)
          LabeledContent(
            "Accessibility", value: status.accessibilityGranted ? "Granted" : "Missing")
          LabeledContent(
            "Input Monitoring", value: status.inputMonitoringGranted ? "Granted" : "Missing")
          LabeledContent("Shortcut listener", value: status.tapActive ? "Active" : "Inactive")
          if let reason = status.tapFailureReason {
            LabeledContent("Listener issue", value: eventTapFailureDescription(reason))
          }
          LabeledContent("Configuration", value: status.configState.rawValue)
          LabeledContent("Bindings", value: "\(status.bindingCount)")

          if !status.unresolvedBundleIDs.isEmpty {
            LabeledContent("Unresolved apps") {
              Text(status.unresolvedBundleIDs.joined(separator: "\n"))
                .textSelection(.enabled)
            }
          }

          if let error = status.lastReloadError {
            LabeledContent("Last reload error") {
              Text(error)
                .textSelection(.enabled)
            }
          }
        } else {
          Text("Agent status unavailable")
            .foregroundStyle(.secondary)
        }

        if let error = serviceManager.lastError {
          LabeledContent("Service error") {
            Text(error)
              .foregroundStyle(.red)
              .textSelection(.enabled)
          }
        }

        if let error = serviceManager.lastStatusItemError {
          LabeledContent("Menu bar error") {
            Text(error)
              .foregroundStyle(.red)
              .textSelection(.enabled)
          }
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 520)
    .scenePadding()
    .task {
      await serviceManager.refresh()
    }
  }

  private func eventTapFailureDescription(_ reason: EventTapFailureReason) -> String {
    switch reason {
    case .accessibilityDenied:
      "Accessibility missing"
    case .inputMonitoringDenied:
      "Input Monitoring missing"
    case .installationFailed:
      "Unavailable"
    case .disabledByTimeout:
      "Timed out"
    case .disabledByUserInput:
      "Disabled by user input"
    }
  }
}
