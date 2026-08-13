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

    let model = SummondModel(storage: FileConfigurationStore())
    _model = State(initialValue: model)
    // Unit tests host this executable; never let that host mutate live services.
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
      return
    }
    if CommandLine.arguments.contains("--restart-agent") {
      Task { @MainActor in
        await model.restartService()
        NSApplication.shared.terminate(nil)
      }
      return
    }
    if CommandLine.arguments.contains("--prepare-uninstall") {
      Task { @MainActor in
        exit(await model.prepareForUninstall(deleteSavedData: false) ? EXIT_SUCCESS : EXIT_FAILURE)
      }
      return
    }
    Task { @MainActor in
      await model.start()
    }
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
