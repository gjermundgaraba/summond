import CoreGraphics
import SummondCore
import SwiftUI

struct ShortcutEditorView: View {
  @Binding var draft: ShortcutEditorDraft
  let applications: [AppDisplayInfo]
  let isLoadingApplications: Bool
  let validationMessages: [String]
  var loadApplications: () async -> Void
  var resolveApplication: (URL) -> AppIdentity?
  var recordShortcut: (CGKeyCode, CGEventFlags) -> ShortcutRecordResult
  var onSave: (ShortcutEditorDraft) async -> String?
  var onCancel: () -> Void

  @State private var isRecording = false
  @State private var recorderError: String?
  @State private var saveError: String?
  @State private var isSaving = false

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 16) {
        Text(draft.editingID == nil ? "Add Shortcut" : "Edit Shortcut")
          .font(.title2.weight(.semibold))

        shortcutSection
        behaviorSection

        AppPickerView(
          draft: $draft,
          applications: applications,
          isLoading: isLoadingApplications,
          loadApplications: loadApplications,
          resolveApplication: resolveApplication
        )
        .frame(maxHeight: .infinity)
      }
      .padding(20)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

      footer
    }
    .frame(width: 680, height: 620)
  }

  private var shortcutSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Shortcut")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)

      ShortcutRecorderView(
        shortcut: $draft.shortcut,
        isRecording: $isRecording,
        errorMessage: $recorderError,
        onRecord: recordShortcut
      )

      Group {
        if let recorderError {
          Label(recorderError, systemImage: "exclamationmark.circle")
            .foregroundStyle(.red)
        }
      }
      .font(.caption)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var behaviorSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Window Behavior")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)

      Text("When the application is already open on another Space:")
        .font(.callout)
        .foregroundStyle(.secondary)

      HStack(alignment: .center, spacing: 24) {
        Picker("Window Behavior", selection: $draft.mode) {
          ForEach(AppOpenMode.allCases, id: \.self) { mode in
            Text(mode.title)
              .tag(mode)
              .help(mode.description)
              .accessibilityIdentifier("editor.mode.\(mode.rawValue)")
          }
        }
        .labelsHidden()
        .pickerStyle(.radioGroup)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("editor.behaviorPicker")

        SpacesAnimationView(mode: draft.mode)
          .frame(width: 190, height: 88)
          .accessibilityHidden(true)
      }

      Text(draft.mode.description)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var footer: some View {
    VStack(spacing: 0) {
      Divider()

      HStack(spacing: 12) {
        if let saveError {
          Label(saveError, systemImage: "exclamationmark.circle")
            .font(.callout)
            .foregroundStyle(.red)
            .lineLimit(2)
            .help(saveError)
            .frame(maxWidth: 390, alignment: .leading)
        } else if let message = validationMessages.first {
          Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .frame(maxWidth: 390, alignment: .leading)
        }

        Spacer()

        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
          .disabled(isSaving)
          .accessibilityIdentifier("editor.cancelButton")

        Button {
          save()
        } label: {
          if isSaving {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("Saving")
          } else {
            Text("Save")
          }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(!canSave)
        .accessibilityIdentifier("editor.saveButton")
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 12)
    }
  }

  private var canSave: Bool {
    validationMessages.isEmpty && recorderError == nil && !isRecording && !isSaving
  }

  private func save() {
    saveError = nil
    isSaving = true
    Task {
      let error = await onSave(draft)
      isSaving = false
      if let error {
        saveError = error
      } else {
        onCancel()
      }
    }
  }
}
