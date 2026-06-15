import KeybinddCore
import SwiftUI

struct BindingListView: View {
  var model: PreferencesViewModel
  @Binding var selection: StoredBinding.ID?
  var addAction: () -> Void

  var body: some View {
    List(selection: $selection) {
      ForEach(model.draft.bindings) { binding in
        BindingRowView(
          binding: binding,
          appInfo: model.displayInfo(for: binding.target.bundleID)
        )
        .tag(binding.id)
        .accessibilityIdentifier("bindingRow.\(binding.target.bundleID)")
        .contentShape(Rectangle())
        .simultaneousGesture(
          TapGesture(count: 2).onEnded {
            model.beginEditing(binding)
          }
        )
        .contextMenu {
          Button("Edit") {
            model.beginEditing(binding)
          }
          Button("Delete", role: .destructive) {
            Task {
              await model.deleteBinding(id: binding.id)
              if selection == binding.id {
                selection = nil
              }
            }
          }
          .accessibilityIdentifier("bindingRow.delete")
        }
      }
    }
    .onKeyPress(.return) {
      guard
        let selection,
        let binding = model.draft.bindings.first(where: { $0.id == selection })
      else {
        return .ignored
      }
      model.beginEditing(binding)
      return .handled
    }
    .overlay {
      if model.draft.bindings.isEmpty {
        EmptyBindingsView(addAction: addAction)
      }
    }
    .onDeleteCommand {
      guard let selection else {
        return
      }
      Task {
        await model.deleteBinding(id: selection)
        self.selection = nil
      }
    }
  }
}

private struct EmptyBindingsView: View {
  var addAction: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "keyboard")
        .font(.system(size: 42, weight: .semibold))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(.secondary)
      Text("No shortcuts yet")
        .font(.title3.weight(.semibold))
      Text("Add a shortcut to open, focus, or move an app window.")
        .foregroundStyle(.secondary)
      Button("Add Shortcut") {
        addAction()
      }
      .buttonStyle(.borderedProminent)
      .accessibilityIdentifier("emptyState.addShortcut")
    }
    .multilineTextAlignment(.center)
  }
}

private struct BindingRowView: View {
  var binding: StoredBinding
  var appInfo: AppDisplayInfo

  var body: some View {
    HStack(spacing: 12) {
      AppRowIcon(url: appInfo.url, size: 34)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(appInfo.displayName)
            .lineLimit(1)
          if !appInfo.isInstalled {
            Text("not installed")
              .font(.caption2.weight(.medium))
              .foregroundStyle(.orange)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(.orange.opacity(0.12), in: Capsule())
          }
        }
        Text(binding.target.bundleID)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer(minLength: 12)

      ShortcutPill(shortcut: binding.shortcut)

      Text(binding.target.mode.title)
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.7), in: Capsule())
    }
    .padding(.vertical, 7)
  }
}

struct ShortcutPill: View {
  var shortcut: Shortcut

  var body: some View {
    Text(ShortcutFormatter.symbols(for: shortcut))
      .font(.system(.callout, design: .rounded).weight(.semibold))
      .foregroundStyle(.primary)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(.regularMaterial, in: Capsule())
      .overlay {
        Capsule()
          .stroke(.separator.opacity(0.8), lineWidth: 1)
      }
      .accessibilityLabel("Shortcut \(ShortcutFormatter.symbols(for: shortcut))")
  }
}
