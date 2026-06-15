import AppKit
import SummondCore
import SwiftUI

struct BindingListView: View {
  var model: PreferencesViewModel
  @Binding var selection: StoredBinding.ID?
  var addAction: () -> Void

  // Double-click-to-edit is driven by a non-consuming local mouse monitor, not a
  // row gesture: any tap gesture on a row races the List's native single-click
  // selection and makes clicks miss. The monitor maps a double-click to a row
  // using `listClickRegion` (a passthrough view that converts the click into the
  // list's coordinate space) and `rowFrames` (each row's frame in that space),
  // without ever competing for the event.
  @State private var listClickRegion: NSView?
  @State private var editorDoubleClickMonitor: Any?
  @State private var rowFrames: [StoredBinding.ID: CGRect] = [:]

  private static let rowSpace = "bindingRows"

  var body: some View {
    List(selection: $selection) {
      ForEach(model.draft.bindings) { binding in
        BindingRowView(
          binding: binding,
          appInfo: model.displayInfo(for: binding.target.bundleID)
        )
        .tag(binding.id)
        .accessibilityIdentifier("bindingRow.\(binding.target.bundleID)")
        // Publish the row's frame for the double-click monitor (see state vars).
        .background(
          GeometryReader { geometry in
            Color.clear.preference(
              key: RowFrameKey.self,
              value: [binding.id: geometry.frame(in: .named(Self.rowSpace))]
            )
          }
        )
        .contextMenu {
          Button("Edit") {
            selection = binding.id
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
    .coordinateSpace(.named(Self.rowSpace))
    .onPreferenceChange(RowFrameKey.self) { frames in
      rowFrames = frames
    }
    .background(
      ListClickRegionReader { view in
        listClickRegion = view
      }
    )
    .onAppear { installDoubleClickMonitor() }
    .onDisappear { removeDoubleClickMonitor() }
  }

  private func installDoubleClickMonitor() {
    guard editorDoubleClickMonitor == nil else {
      return
    }
    editorDoubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
      event in
      // Fires on the main thread; the event is returned unchanged so the click
      // still drives the List's own selection.
      MainActor.assumeIsolated {
        handlePotentialDoubleClick(event)
      }
      return event
    }
  }

  private func removeDoubleClickMonitor() {
    if let editorDoubleClickMonitor {
      NSEvent.removeMonitor(editorDoubleClickMonitor)
    }
    editorDoubleClickMonitor = nil
  }

  private func handlePotentialDoubleClick(_ event: NSEvent) {
    guard
      event.clickCount == 2,
      let region = listClickRegion,
      region.window == event.window
    else {
      return
    }

    // Edit only when the double-click hit an actual row, so empty list space,
    // the toolbar, and the title bar are ignored.
    let point = region.convert(event.locationInWindow, from: nil)
    guard
      let id = rowFrames.first(where: { $0.value.contains(point) })?.key,
      let binding = model.draft.bindings.first(where: { $0.id == id })
    else {
      return
    }

    selection = id
    model.beginEditing(binding)
  }
}

/// Installs a transparent, event-transparent NSView that tracks the List's
/// bounds. `hitTest` returns nil so the view never participates in event
/// routing — it exists purely to convert screen/window coordinates into the
/// list's coordinate space for the double-click monitor.
private struct ListClickRegionReader: NSViewRepresentable {
  var onResolve: (NSView) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = PassthroughView()
    DispatchQueue.main.async {
      onResolve(view)
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}

  private final class PassthroughView: NSView {
    // Match SwiftUI's top-left origin so window->view coordinate conversion
    // lines up with the row frames captured in SwiftUI coordinate spaces.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
      nil
    }
  }
}

/// Row frames in the list's coordinate space, keyed by binding, so a
/// double-click can be matched to the row under the cursor.
private struct RowFrameKey: PreferenceKey {
  static let defaultValue: [StoredBinding.ID: CGRect] = [:]

  static func reduce(
    value: inout [StoredBinding.ID: CGRect],
    nextValue: () -> [StoredBinding.ID: CGRect]
  ) {
    value.merge(nextValue()) { _, new in new }
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

      Spacer(minLength: 16)

      // Shortcut pill and mode badge form one right-anchored group: the pill
      // sits in a fixed column so the keys line up across rows, and the badge is
      // flush to the trailing edge so there is a clean right margin instead of
      // each badge floating with leftover space.
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
    }
    .padding(.vertical, 8)
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
