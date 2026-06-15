import AppKit
import CoreGraphics
import SummondCore
import SwiftUI

struct ShortcutRecorderView: View {
  @Binding var shortcut: ShortcutDraft
  @Binding var isRecording: Bool
  @Binding var errorMessage: String?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var isFocused: Bool
  var onRecord: (CGKeyCode, CGEventFlags) -> String?

  var body: some View {
    HStack(spacing: 5) {
      if isRecording {
        Image(systemName: "keyboard")
          .foregroundStyle(.tint)
        Text("Type shortcut...  esc to cancel")
          .font(.callout)
          .foregroundStyle(.tint)
        Spacer(minLength: 0)
      } else if shortcut.isEmpty {
        Image(systemName: "record.circle")
          .foregroundStyle(.secondary)
        Text("Click to record")
          .font(.callout)
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
      } else {
        ForEach(ShortcutFormatter.tokens(for: shortcut), id: \.self) { token in
          KeyCapView(glyph: token)
        }
        Spacer(minLength: 4)
        Button {
          shortcut = .empty
          errorMessage = nil
        } label: {
          Image(systemName: "xmark.circle.fill")
            .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Clear shortcut")
        .accessibilityLabel("Clear shortcut")
      }
    }
    .padding(.horizontal, 8)
    .frame(width: 260, height: 30)
    .background(
      isRecording
        ? Color.accentColor.opacity(0.12)
        : Color(nsColor: .quaternaryLabelColor)
          .opacity(0.18),
      in: RoundedRectangle(cornerRadius: 6, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(
          isRecording ? Color.accentColor : Color(nsColor: .separatorColor),
          lineWidth: isRecording ? 1.5 : 1
        )
    }
    .overlay {
      if isFocused && !isRecording {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(Color.accentColor, lineWidth: 2)
          .padding(-3)
      }
    }
    .background(
      ShortcutRecorderBridge(
        shortcut: $shortcut,
        isRecording: $isRecording,
        errorMessage: $errorMessage,
        onRecord: onRecord
      )
    )
    .contentShape(Rectangle())
    .focusable(true)
    .focused($isFocused)
    .onKeyPress(.return) {
      startRecording()
      return .handled
    }
    .onKeyPress(.space) {
      startRecording()
      return .handled
    }
    .onTapGesture {
      startRecording()
    }
    .accessibilityElement(children: .ignore)
    .accessibilityIdentifier("editor.shortcutRecorder")
    .accessibilityLabel("Shortcut recorder")
    .accessibilityValue(accessibilityValue)
    .accessibilityHint("Activate to record a shortcut")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction(.default) {
      startRecording()
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isRecording)
  }

  private var accessibilityValue: String {
    if isRecording {
      return "recording"
    }
    guard let shortcut = shortcut.shortcut else {
      return "no shortcut"
    }
    return ShortcutFormatter.symbols(for: shortcut)
  }

  private func startRecording() {
    if !isRecording {
      errorMessage = nil
      isRecording = true
      // Do NOT drive `isFocused` here. The AppKit recorder view takes first
      // responder to capture the keystroke (see ShortcutRecorderNSView); forcing
      // SwiftUI focus state in the same turn races that hand-off and can yank
      // first responder back out, which fires resignFirstResponder() ->
      // cancelRecordingIfNeeded() and cancels recording the instant it starts.
    }
  }
}

struct KeyCapView: View {
  let glyph: String

  var body: some View {
    Text(glyph)
      .font(.system(.callout, design: .rounded).weight(.semibold))
      .frame(minWidth: 22, minHeight: 22)
      .padding(.horizontal, glyph.count > 1 ? 6 : 2)
      .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5))
      .overlay {
        RoundedRectangle(cornerRadius: 5)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
      }
      .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
  }
}

private struct ShortcutRecorderBridge: NSViewRepresentable {
  @Binding var shortcut: ShortcutDraft
  @Binding var isRecording: Bool
  @Binding var errorMessage: String?
  var onRecord: (CGKeyCode, CGEventFlags) -> String?

  func makeNSView(context: Context) -> ShortcutRecorderNSView {
    let view = ShortcutRecorderNSView()
    view.onBeginRecording = {
      isRecording = true
      errorMessage = nil
    }
    view.onCancelRecording = {
      isRecording = false
      errorMessage = nil
    }
    view.onRecord = { keyCode, flags in
      if let message = onRecord(keyCode, flags) {
        errorMessage = message
        return false
      } else {
        errorMessage = nil
        isRecording = false
        return true
      }
    }
    return view
  }

  func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
    if nsView.isRecording != isRecording {
      nsView.isRecording = isRecording
    }
  }
}

final class ShortcutRecorderNSView: NSView {
  var onBeginRecording: (() -> Void)?
  var onCancelRecording: (() -> Void)?
  var onRecord: ((CGKeyCode, CGEventFlags) -> Bool)?

  var isRecording = false {
    didSet {
      if isRecording {
        window?.makeFirstResponder(self)
      } else if !isResigningFirstResponder, window?.firstResponder == self {
        window?.makeFirstResponder(nil)
      }
    }
  }

  private var isResigningFirstResponder = false
  private var windowResignKeyObserver: NSObjectProtocol?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var acceptsFirstResponder: Bool {
    true
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let windowResignKeyObserver {
      NotificationCenter.default.removeObserver(windowResignKeyObserver)
      self.windowResignKeyObserver = nil
    }

    guard let window else {
      cancelRecordingIfNeeded()
      return
    }

    windowResignKeyObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification,
      object: window,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.cancelRecordingIfNeeded()
      }
    }
  }

  // The observer is registered against the view's window and removed in
  // viewDidMoveToWindow(nil), which SwiftUI triggers when the editor window
  // closes and the view leaves the hierarchy. A nonisolated deinit cannot read
  // the non-Sendable observer token under Swift 6, and the cleanup there would
  // be redundant.

  override func mouseDown(with event: NSEvent) {
    onBeginRecording?()
    window?.makeFirstResponder(self)
  }

  override func keyDown(with event: NSEvent) {
    guard isRecording else {
      super.keyDown(with: event)
      return
    }
    handle(event)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard isRecording else {
      return false
    }
    handle(event)
    return true
  }

  private func handle(_ event: NSEvent) {
    guard isRecording else {
      return
    }

    if event.keyCode == 0x35 {
      cancelRecordingIfNeeded()
      return
    }

    let didRecord =
      onRecord?(
        event.keyCode,
        CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
      ) ?? false
    if didRecord {
      isRecording = false
    }
  }

  override func resignFirstResponder() -> Bool {
    isResigningFirstResponder = true
    defer {
      isResigningFirstResponder = false
    }
    cancelRecordingIfNeeded()
    return super.resignFirstResponder()
  }

  private func cancelRecordingIfNeeded() {
    if isRecording {
      isRecording = false
      onCancelRecording?()
    }
  }
}
