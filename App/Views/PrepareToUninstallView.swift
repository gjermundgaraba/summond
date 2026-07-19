import SwiftUI

struct PrepareToUninstallView: View {
  var model: SummondModel
  let applicationManager: any UninstallApplicationManaging

  @State private var deleteSavedData = false
  @State private var revealAndTerminateOnDismiss = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top, spacing: 14) {
        Image(systemName: "trash.circle.fill")
          .font(.system(size: 34))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(.red)

        VStack(alignment: .leading, spacing: 6) {
          Text("Prepare to Uninstall Summond?")
            .font(.title2.weight(.semibold))

          Text(
            "Summond will stop its background service and menu bar item, then quit and reveal itself in Finder so you can move it to the Trash."
          )
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }

      Toggle("Delete saved shortcuts and settings", isOn: $deleteSavedData)
        .toggleStyle(.checkbox)
        .disabled(model.isPreparingToUninstall)
        .accessibilityIdentifier("uninstall.deleteSavedData")

      if deleteSavedData {
        Text("Saved shortcuts and preferences will be permanently deleted. This cannot be undone.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      if let error = model.uninstallPreparationError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.red)
          .textSelection(.enabled)
          .accessibilityIdentifier("uninstall.error")
      }

      if model.isPreparingToUninstall {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Preparing to uninstall…")
            .foregroundStyle(.secondary)
        }
      }

      HStack {
        Spacer()

        Button("Cancel", role: .cancel) {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        .disabled(model.isPreparingToUninstall)

        Button("Prepare and Quit", role: .destructive) {
          Task {
            guard await model.prepareForUninstall(deleteSavedData: deleteSavedData) else {
              return
            }
            // Terminating while this sheet is still presented silently stalls:
            // SwiftUI's application delegate never completes termination while
            // a sheet is up. Dismiss first and terminate from onDisappear.
            revealAndTerminateOnDismiss = true
            dismiss()
          }
        }
        .disabled(model.isPreparingToUninstall)
        .accessibilityIdentifier("uninstall.prepareAndQuit")
      }
    }
    .padding(24)
    .frame(width: 460)
    .interactiveDismissDisabled(model.isPreparingToUninstall)
    .onDisappear {
      guard revealAndTerminateOnDismiss else {
        return
      }
      // Let the dismissal transaction finish before terminating so the app
      // is not torn down mid-update.
      DispatchQueue.main.async {
        applicationManager.revealInFinderAndTerminate(applicationURL: Bundle.main.bundleURL)
      }
    }
  }
}
