import KeybinddCore
import SwiftUI

struct BindingEditorView: View {
  var model: PreferencesViewModel
  @Binding var editorDraft: BindingEditorDraft
  @State private var isRecording = false
  @State private var recorderError: String?

  private func allValidationMessages(from messages: [String]) -> [String] {
    var messages = messages
    if let recorderError {
      messages.insert(recorderError, at: 0)
    }
    var seen: Set<String> = []
    return messages.filter { seen.insert($0).inserted }
  }

  private func canSave(with messages: [String]) -> Bool {
    allValidationMessages(from: messages).isEmpty && !model.isSaving
  }

  var body: some View {
    let messages = model.validationMessages(for: editorDraft)

    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 14) {
        shortcutSection
        modeSection
        AppPickerView(model: model, editorDraft: $editorDraft)
          .frame(maxHeight: .infinity)
      }
      .padding(.horizontal, 20)
      .padding(.top, 16)
      .padding(.bottom, 12)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

      footer(validationMessages: messages)
    }
    .frame(minWidth: 580, idealWidth: 580, minHeight: 560, idealHeight: 660)
  }

  private var shortcutSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Shortcut")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)

      ShortcutRecorderView(
        shortcut: $editorDraft.shortcut,
        isRecording: $isRecording,
        errorMessage: $recorderError
      ) { keyCode, flags in
        model.recordShortcut(keyCode: keyCode, flags: flags)
      }

      shortcutCaption
    }
  }

  private var shortcutCaption: some View {
    HStack(spacing: 5) {
      if let recorderError {
        Image(systemName: "exclamationmark.circle")
        Text(recorderError)
          .lineLimit(1)
          .truncationMode(.tail)
      } else if let caution = model.cautionMessage(for: editorDraft) {
        Image(systemName: "info.circle")
        Text(caution)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .font(.caption)
    .foregroundStyle(recorderError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
    .frame(height: 18, alignment: .leading)
  }

  private var modeSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Open Mode")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)

      Picker("Open Mode", selection: $editorDraft.mode) {
        ForEach(AppOpenMode.allCases, id: \.self) { mode in
          Text(mode.shortTitle).tag(mode)
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .accessibilityIdentifier("editor.modePicker")

      HStack(spacing: 14) {
        SpacesAnimationView(mode: editorDraft.mode)
          .frame(width: 170, height: 76)

        VStack(alignment: .leading, spacing: 4) {
          Text(editorDraft.mode.title)
            .font(.headline)
          Text(editorDraft.mode.description)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
      .padding(12)
      .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
      .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
  }

  private func footer(validationMessages: [String]) -> some View {
    VStack(spacing: 0) {
      Divider()
      HStack(spacing: 12) {
        validationSummary(validationMessages)
        Spacer()

        Button("Cancel") {
          model.cancelEditing()
        }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("editor.cancelButton")

        Button("Save") {
          Task {
            await model.commitEditorDraftAndSave()
          }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(!canSave(with: validationMessages))
        .accessibilityIdentifier("editor.saveButton")
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 12)
    }
  }

  @ViewBuilder
  private func validationSummary(_ validationMessages: [String]) -> some View {
    if let message = validationMessages.first {
      Label(message, systemImage: "exclamationmark.circle")
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .help(validationMessages.joined(separator: "\n"))
        .frame(maxWidth: 300, alignment: .leading)
    }
  }
}

struct BindingEditorWindowRoot: View {
  var model: PreferencesViewModel
  @Environment(\.dismissWindow) private var dismissWindow
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    Group {
      if let draft = model.editorDraft {
        BindingEditorView(
          model: model,
          editorDraft: Binding(
            get: { model.editorDraft ?? draft },
            set: { model.editorDraft = $0 }
          )
        )
        .navigationTitle(draft.editingID == nil ? "Add Binding" : "Edit Binding")
      } else {
        Color.clear
          .frame(minWidth: 580, idealWidth: 580, minHeight: 560, idealHeight: 660)
      }
    }
    .onDisappear {
      if model.editorDraft != nil {
        model.cancelEditing()
      }
    }
    .onChange(of: model.editorDraft == nil) { _, isNil in
      if isNil {
        dismissWindow(id: "binding-editor")
        dismiss()
      }
    }
  }
}
