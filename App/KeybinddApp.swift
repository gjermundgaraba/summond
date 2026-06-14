import AppKit
import KeybinddCore
import OSLog
import SwiftUI

@main
struct KeybinddApp: App {
  @State private var serviceManager: ServiceManager
  @State private var preferencesModel: PreferencesViewModel

  init() {
    let agentClient = AgentClient()
    let store: any ConfigurationStore
    let storageBanner: PreferencesBanner?
    if let userDefaultsStore = UserDefaultsConfigurationStore() {
      store = userDefaultsStore
      storageBanner = nil
    } else {
      KeybinddLoggers.config.fault(
        "Settings storage unavailable; falling back to in-memory configuration")
      store = InMemoryConfigurationStore()
      storageBanner = PreferencesBanner(
        tone: .error,
        title: "Settings storage unavailable",
        message: "Changes won't be saved."
      )
    }
    let serviceManager = ServiceManager(agentClient: agentClient)
    let preferencesModel = PreferencesViewModel(
      store: store,
      agentClient: agentClient,
      initialBanner: storageBanner
    )
    preferencesModel.onAgentStatusReloaded = { [weak serviceManager] status in
      serviceManager?.acceptReloadedStatus(status)
    }
    _serviceManager = State(initialValue: serviceManager)
    _preferencesModel = State(initialValue: preferencesModel)
  }

  var body: some Scene {
    WindowGroup(id: "preferences") {
      ContentView(serviceManager: serviceManager, preferencesModel: preferencesModel)
        .frame(minWidth: 760, minHeight: 520)
        .onOpenURL(perform: handleURL)
    }
    .handlesExternalEvents(matching: ["preferences"])
    .commands {
      KeybinddShortcutCommands()
    }

    Window("Binding", id: "binding-editor") {
      BindingEditorWindowRoot(model: preferencesModel)
    }
    .windowResizability(.contentMinSize)
    .defaultWindowPlacement { content, context in
      let idealSize = content.sizeThatFits(.unspecified)
      let visibleRect = context.defaultDisplay.visibleRect
      return WindowPlacement(
        size: CGSize(
          width: min(idealSize.width, visibleRect.width),
          height: min(idealSize.height, visibleRect.height)
        )
      )
    }
    .restorationBehavior(.disabled)
    .commandsRemoved()

    Settings {
      SettingsView(serviceManager: serviceManager, preferencesModel: preferencesModel)
    }
  }

  private func handleURL(_ url: URL) {
    guard url.scheme == "keybindd" else {
      return
    }

    NSApp.activate()
    for window in NSApp.windows {
      if window.identifier?.rawValue == "binding-editor" {
        continue
      }
      window.makeKeyAndOrderFront(nil)
    }

    switch url.host {
    case "preferences":
      Task {
        await serviceManager.refresh()
      }
    default:
      break
    }
  }
}

private struct KeybinddShortcutCommands: Commands {
  @FocusedValue(\.preferencesCommands) private var commands

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("Add Shortcut") {
        commands?.add()
      }
      .keyboardShortcut("n", modifiers: [.command])
      .disabled(commands == nil)
    }

    CommandMenu("Shortcuts") {
      Button("Edit Shortcut") {
        commands?.edit()
      }
      .keyboardShortcut(.return, modifiers: [.command])
      .disabled(commands?.canEdit != true)

      Button("Delete Shortcut") {
        commands?.delete()
      }
      .keyboardShortcut(.delete, modifiers: [])
      .disabled(commands?.canDelete != true)

      Divider()

      Button("Reload Bindings") {
        commands?.reload()
      }
      .keyboardShortcut("r", modifiers: [.command])
      .disabled(commands?.canReload != true)
    }
  }
}
