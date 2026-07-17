import SummondCore
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
    .frame(minWidth: 580, idealWidth: 580, minHeight: 680, idealHeight: 800)
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
      Text("Window Behavior")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)

      Text(
        "Summond launches the app if needed. When it's already open on another Space:"
      )
      .font(.callout)
      .foregroundStyle(.secondary)

      VStack(spacing: 8) {
        ForEach(AppOpenMode.allCases, id: \.self) { mode in
          modeChoice(mode)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Window Behavior")
      .accessibilityIdentifier("editor.modeChoices")
    }
  }

  private func modeChoice(_ mode: AppOpenMode) -> some View {
    let isSelected = editorDraft.mode == mode

    return Button {
      editorDraft.mode = mode
    } label: {
      HStack(spacing: 12) {
        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
          .font(.system(size: 15))
          .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 4) {
          Text(mode.title)
            .font(.body.weight(.semibold))
          Text(mode.description)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 0)

        SpacesAnimationView(mode: mode)
          .frame(width: 170, height: 76)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(
      isSelected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06),
      in: RoundedRectangle(cornerRadius: 8)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(
          isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
          lineWidth: isSelected ? 1.5 : 1
        )
    }
    .accessibilityLabel(mode.title)
    .accessibilityValue(isSelected ? "Selected" : "Not selected")
    .accessibilityHint(mode.description)
    .accessibilityIdentifier("editor.mode.\(mode.rawValue)")
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
          .frame(minWidth: 580, idealWidth: 580, minHeight: 680, idealHeight: 800)
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
