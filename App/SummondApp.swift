import OSLog
import SummondCore
import SwiftUI

// In a SMOKE_TEST build the process entry point is `SmokeTest` (see
// SmokeTest.swift), so `SummondApp` is compiled but not the `@main` type.
#if !SMOKE_TEST
  @main
#endif
struct SummondApp: App {
  @State private var model: SummondModel

  #if DEBUG
    @NSApplicationDelegateAdaptor(UITestAppDelegate.self) private var uiTestAppDelegate
  #endif

  init() {
    #if DEBUG
      if UITestHarness.isActive {
        _model = State(initialValue: UITestHarness.makeModel())
        return
      }
    #endif

    let storage: SummondModel.ConfigurationStorage
    if let userDefaultsStore = UserDefaultsConfigurationStore() {
      storage = .available(userDefaultsStore)
    } else {
      let message = "Changes cannot be saved because settings storage is unavailable."
      SummondLoggers.config.fault("Settings storage unavailable")
      storage = .unavailable(message)
    }

    _model = State(
      initialValue: SummondModel(
        storage: storage
      ))
  }

  var body: some Scene {
    WindowGroup(id: "preferences") {
      ContentView(model: model)
        .frame(minWidth: 760, minHeight: 520)
    }
    .handlesExternalEvents(matching: ["preferences", "setup", "settings"])
    .commands {
      SummondShortcutCommands()
    }

    Settings {
      SettingsView(model: model)
    }
  }

}

private struct SummondShortcutCommands: Commands {
  @FocusedValue(\.shortcutCommands) private var commands

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
    }
  }
}
