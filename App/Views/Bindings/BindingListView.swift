import SummondCore
import SwiftUI

struct BindingListView: View {
  let bindings: [StoredBinding]
  @Binding var selection: StoredBinding.ID?
  var displayInfo: (String) -> AppDisplayInfo
  var onAdd: () -> Void
  var onEdit: (StoredBinding) -> Void
  var onDelete: (StoredBinding) -> Void

  var body: some View {
    List(selection: $selection) {
      ForEach(bindings) { binding in
        BindingRowView(
          binding: binding,
          appInfo: displayInfo(binding.target.bundleID)
        )
        .tag(binding.id)
        .contextMenu {
          Button("Edit Shortcut") {
            onEdit(binding)
          }
          .accessibilityIdentifier("shortcutRow.edit")

          Button("Delete Shortcut", role: .destructive) {
            onDelete(binding)
          }
          .accessibilityIdentifier("shortcutRow.delete")
        }
      }
    }
    .overlay {
      if bindings.isEmpty {
        EmptyShortcutsView(onAdd: onAdd)
      }
    }
    .onKeyPress(.return) {
      guard let selectedBinding else { return .ignored }
      onEdit(selectedBinding)
      return .handled
    }
    .onDeleteCommand {
      guard let selectedBinding else { return }
      onDelete(selectedBinding)
    }
  }

  private var selectedBinding: StoredBinding? {
    guard let selection else { return nil }
    return bindings.first { $0.id == selection }
  }
}

private struct EmptyShortcutsView: View {
  var onAdd: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label("No Shortcuts", systemImage: "keyboard")
    } description: {
      Text("Add a shortcut to open, focus, or move an app window.")
    } actions: {
      Button("Add Shortcut", action: onAdd)
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("emptyState.addShortcut")
    }
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
            Text("Not Installed")
              .font(.caption2.weight(.medium))
              .foregroundStyle(.orange)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(.orange.opacity(0.12), in: Capsule())
          }
        }

        if !appInfo.isInstalled {
          Text(binding.target.bundleID)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      Spacer(minLength: 16)

      HStack(spacing: 10) {
        ShortcutPill(shortcut: binding.shortcut)
          .frame(minWidth: 52, alignment: .trailing)

        Text(binding.target.mode.title)
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(.quaternary.opacity(0.7), in: Capsule())
          .frame(width: 150, alignment: .trailing)
      }
      .accessibilityHidden(true)
    }
    .padding(.vertical, 8)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(rowAccessibilityLabel)
    .accessibilityIdentifier("shortcutRow.\(binding.id.uuidString)")
  }

  private var rowAccessibilityLabel: String {
    let installation = appInfo.isInstalled ? "" : ", not installed"
    return
      "\(appInfo.displayName)\(installation), \(spokenShortcut(binding.shortcut)), \(binding.target.mode.title)"
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
        Capsule().stroke(.separator.opacity(0.8), lineWidth: 1)
      }
      .accessibilityLabel("Shortcut \(spokenShortcut(shortcut))")
  }
}

func spokenShortcut(_ shortcut: Shortcut) -> String {
  let modifierNames = shortcut.mods.compactMap { modifier in
    switch modifier.lowercased() {
    case "ctrl", "control": "Control"
    case "alt", "opt", "option": "Option"
    case "shift": "Shift"
    case "cmd", "command": "Command"
    default: nil
    }
  }
  return (modifierNames + [ShortcutFormatter.keyTitle(shortcut.key)]).joined(separator: " ")
}
