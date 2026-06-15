import AppKit
import KeybinddCore
import SwiftUI
import UniformTypeIdentifiers

struct AppPickerView: View {
  var model: PreferencesViewModel
  @Binding var editorDraft: BindingEditorDraft
  @State private var searchText = ""
  @State private var dropError: String?

  private var selectedInfo: AppDisplayInfo? {
    editorDraft.bundleID.isEmpty ? nil : model.displayInfo(for: editorDraft.bundleID)
  }

  private var filteredApps: [AppDisplayInfo] {
    AppFuzzyMatch.rank(model.installedApplications, searchText)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Target App")
        Spacer()
        Button("Choose App...") {
          chooseApplication()
        }
      }

      targetWell

      if let dropError {
        Text(dropError)
          .font(.callout)
          .foregroundStyle(.red)
      }

      Group {
        if model.installedAppsLoading {
          HStack(spacing: 8) {
            ProgressView()
              .controlSize(.small)
            Text("Loading installed apps...")
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, minHeight: 150)
        } else {
          List(filteredApps) { app in
            Button {
              editorDraft.bundleID = app.bundleID
            } label: {
              HStack(spacing: 10) {
                AppRowIcon(url: app.url)
                VStack(alignment: .leading, spacing: 2) {
                  Text(app.displayName)
                    .lineLimit(1)
                  Text(app.bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer()
                if app.bundleID == editorDraft.bundleID {
                  Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                }
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityIdentifier("appRow.\(app.bundleID)")
          }
          .frame(maxHeight: .infinity)
          .searchable(text: $searchText, prompt: "Search apps")
        }
      }
      .frame(maxHeight: .infinity)
    }
    .frame(maxHeight: .infinity)
    .task {
      await model.loadInstalledApplicationsIfNeeded()
    }
  }

  private var targetWell: some View {
    HStack(spacing: 12) {
      AppRowIcon(url: selectedInfo?.url, size: 36)
      VStack(alignment: .leading, spacing: 3) {
        Text(selectedInfo?.displayName ?? "Drop an app here")
          .font(.body.weight(.medium))
        Text(selectedInfo?.bundleID ?? "Applications only")
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      Spacer()
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
      guard let provider = providers.first else {
        return false
      }

      provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) {
        data,
        _ in
        guard
          let data,
          let url = URL(dataRepresentation: data, relativeTo: nil)
        else {
          Task { @MainActor in
            dropError = "Drop a valid .app bundle."
          }
          return
        }

        Task { @MainActor in
          applyApplicationURL(url)
        }
      }
      return true
    }
  }

  private func chooseApplication() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.applicationBundle]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.resolvesAliases = true

    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }

    applyApplicationURL(url)
  }

  private func applyApplicationURL(_ url: URL) {
    guard let identity = model.identity(forApplicationURL: url) else {
      dropError = "Choose a valid .app bundle."
      return
    }

    dropError = nil
    editorDraft.bundleID = identity.bundleIdentifier
  }
}
