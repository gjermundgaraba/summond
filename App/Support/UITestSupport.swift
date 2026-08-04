#if DEBUG
  import AppKit
  import Foundation
  import SummondCore
  import SwiftUI

  /// Test-only app delegate that materializes AppKit host windows in the headless
  /// Tart session. The hosted SwiftUI views and model are the production types.
  @MainActor
  final class UITestAppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: UITestWindowCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
      guard UITestHarness.isActive, let model = UITestHarness.sharedModel else { return }
      let coordinator = UITestWindowCoordinator(model: model)
      self.coordinator = coordinator
      coordinator.start()
    }
  }

  @MainActor
  final class UITestWindowCoordinator {
    private let model: SummondModel
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var settingsShortcutMonitor: Any?

    init(model: SummondModel) {
      self.model = model
    }

    func start() {
      NSApplication.shared.setActivationPolicy(.regular)
      showMainWindow()
      installSettingsShortcut()
      NSApplication.shared.activate()
    }

    private func showMainWindow() {
      let root = ContentView(model: model)
        .frame(minWidth: 760, minHeight: 520)
      let controller = NSHostingController(rootView: root)
      controller.sceneBridgingOptions = [.title, .toolbars]
      let window = NSWindow(contentViewController: controller)
      window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
      window.setContentSize(NSSize(width: 900, height: 640))
      window.title = "Summond"
      window.center()
      window.makeKeyAndOrderFront(nil)
      mainWindow = window
    }

    private func installSettingsShortcut() {
      settingsShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
        [weak self] event in
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "," {
          self?.showSettingsWindow()
          return nil
        }
        return event
      }
    }

    private func showSettingsWindow() {
      if let settingsWindow {
        settingsWindow.makeKeyAndOrderFront(nil)
        return
      }
      let controller = NSHostingController(
        rootView: SettingsView(
          model: model,
          uninstallApplicationManager: UITestUninstallApplicationManager()
        ))
      let window = NSWindow(contentViewController: controller)
      window.styleMask = [.titled, .closable]
      window.setContentSize(NSSize(width: 560, height: 470))
      window.title = "Settings"
      window.center()
      window.makeKeyAndOrderFront(nil)
      settingsWindow = window
    }
  }

  /// Debug-only dependency injection for the XCUITest suite.
  enum UITestHarness {
    static var isActive: Bool {
      ProcessInfo.processInfo.arguments.contains("-summondUITests")
    }

    static var allowsSystemPermissionFlow: Bool {
      env("SUMMOND_UITEST_PERMISSION_FLOW") == "1"
    }

    @MainActor static var sharedModel: SummondModel?

    static var prefilledDraftShortcut: ShortcutDraft? {
      guard let raw = env("SUMMOND_UITEST_DRAFT_SHORTCUT"), !raw.isEmpty else { return nil }
      var parts = raw.split(separator: "+").map(String.init)
      guard let key = parts.popLast() else { return nil }
      return ShortcutDraft(key: key, mods: parts)
    }

    @MainActor
    static func makeModel() -> SummondModel {
      let store = makeStore()
      let agentClient = UITestAgentClient(
        accessibilityGranted: flag("SUMMOND_UITEST_ACCESSIBILITY", default: true),
        reloadFails: env("SUMMOND_UITEST_RELOAD") == "fail",
        store: store
      )
      let model = SummondModel(
        storage: store,
        agentClient: agentClient,
        agentService: UITestLoginItemService(status: .enabled),
        statusItemService: UITestLoginItemService(status: .notRegistered),
        appCatalog: UITestAppCatalog(),
        savedDataRemover: UITestSavedDataRemover()
      )
      sharedModel = model
      return model
    }

    private static func makeStore() -> any ConfigurationStore {
      if let path = env("SUMMOND_UITEST_CONFIG_PATH") {
        return FileConfigurationStore(url: URL(fileURLWithPath: path))
      }
      return makeInMemoryStore()
    }

    private static func makeInMemoryStore() -> InMemoryConfigurationStore {
      switch env("SUMMOND_UITEST_SEED") {
      case "corrupt":
        return InMemoryConfigurationStore(data: Data("not-valid-summond-json".utf8))
      case "one":
        return seededStore(shortcuts: [shortcut("com.apple.Safari", key: "f")])
      case "two":
        return seededStore(shortcuts: [
          shortcut("com.apple.Safari", key: "f"),
          shortcut("com.apple.Terminal", key: "t"),
        ])
      default:
        return InMemoryConfigurationStore()
      }
    }

    private static func seededStore(shortcuts: [StoredBinding]) -> InMemoryConfigurationStore {
      let store = InMemoryConfigurationStore()
      try! store.save(SummondConfiguration(bindings: shortcuts))
      return store
    }

    private static func shortcut(_ bundleID: String, key: String) -> StoredBinding {
      StoredBinding(
        shortcut: Shortcut(key: key, mods: ["cmd"]),
        target: try! AppTarget(bundleID: bundleID, mode: .launch)
      )
    }

    private static func env(_ key: String) -> String? {
      ProcessInfo.processInfo.environment[key]
    }

    private static func flag(_ key: String, default defaultValue: Bool) -> Bool {
      guard let value = env(key) else { return defaultValue }
      return value != "0"
    }
  }

  struct UITestAgentClient: AgentClientProtocol {
    let accessibilityGranted: Bool
    var reloadFails = false
    let store: any ConfigurationStore

    func status() async throws -> AgentStatus { makeStatus() }

    func reloadConfiguration() async throws -> AgentStatus {
      if reloadFails { throw CocoaError(.xpcConnectionInvalid) }
      return makeStatus()
    }

    func requestAccessibilityPrompt() async throws {}
    func requestInputMonitoringPrompt() async throws {}

    private func makeStatus() -> AgentStatus {
      let configState: AgentConfigurationState
      let bindingCount: Int
      let configurationError: String?

      do {
        if let configuration = try store.load() {
          configState = .ok
          bindingCount = configuration.bindings.count
        } else {
          configState = .fresh
          bindingCount = 0
        }
        configurationError = nil
      } catch let corruption as ConfigurationCorruption {
        configState = AgentConfigurationState(corruption: corruption)
        bindingCount = 0
        configurationError = corruption.localizedDescription
      } catch {
        configState = .unavailable
        bindingCount = 0
        configurationError = error.localizedDescription
      }

      return AgentStatus(
        agentVersion: "uitest",
        accessibilityGranted: accessibilityGranted,
        inputMonitoringGranted: true,
        tapActive: accessibilityGranted,
        configState: configState,
        bindingCount: bindingCount,
        lastReloadError: configurationError
      )
    }
  }

  struct UITestLoginItemService: LoginItemServiceManaging {
    let status: ServiceRegistrationStatus
    func register() async throws {}
    func unregister() async throws {}
    func openSystemSettingsLoginItems() {}
  }

  @MainActor
  struct UITestUninstallApplicationManager: UninstallApplicationManaging {
    func revealInFinderAndTerminate(applicationURL: URL) {}
  }

  struct UITestSavedDataRemover: SavedDataRemoving {
    func removeAllSavedData() throws {}
  }

  struct UITestAppCatalog: AppDisplayResolving {
    private static let applications: [AppDisplayInfo] = [
      .installed(
        bundleID: "com.apple.Safari", displayName: "Safari",
        url: URL(fileURLWithPath: "/Applications/Safari.app")),
      .installed(
        bundleID: "com.apple.Terminal", displayName: "Terminal",
        url: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")),
      .installed(
        bundleID: "com.apple.TextEdit", displayName: "TextEdit",
        url: URL(fileURLWithPath: "/System/Applications/TextEdit.app")),
    ]

    @MainActor
    func displayInfo(for bundleID: String) -> AppDisplayInfo {
      Self.applications.first { $0.bundleID == bundleID } ?? .missing(bundleID: bundleID)
    }

    @MainActor
    func identity(forApplicationURL url: URL) -> AppIdentity? { nil }

    @MainActor
    func installedApplications() async -> [AppDisplayInfo] { Self.applications }
  }
#endif
