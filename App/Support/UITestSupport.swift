#if DEBUG
  import AppKit
  import Foundation
  import SummondCore
  import Observation
  import SwiftUI

  /// Test-only app delegate that nudges the app to the foreground and orders its
  /// window on screen. When XCUITest spawns the app in the headless VM session it
  /// comes up without its `WindowGroup` window materialized on screen (a normal
  /// Finder/LaunchServices launch does not hit this), so the AX tree exposes only
  /// the menu bar. Gated on the UI-test flag, so normal Debug runs are unaffected.
  @MainActor
  final class UITestAppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: UITestWindowCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
      guard UITestHarness.isActive, let dependencies = UITestHarness.sharedDependencies else {
        return
      }
      let coordinator = UITestWindowCoordinator(
        serviceManager: dependencies.0,
        preferencesModel: dependencies.1
      )
      self.coordinator = coordinator
      coordinator.start()
    }
  }

  /// SwiftUI scene windows (`WindowGroup`, `Window`, `Settings`) do not render
  /// when the app is spawned in the headless Tart VM used for UI testing — even
  /// a trivial `WindowGroup` produces no on-screen window — while AppKit windows
  /// do. In UI-test mode this coordinator hosts the *real* SwiftUI views in
  /// AppKit windows so XCUITest can drive them. The views, view models, and the
  /// persistence path are the production code; only the window chrome differs.
  @MainActor
  final class UITestWindowCoordinator {
    private let serviceManager: ServiceManager
    private let preferencesModel: PreferencesViewModel
    private var mainWindow: NSWindow?
    private var editorWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var settingsShortcutMonitor: Any?

    init(serviceManager: ServiceManager, preferencesModel: PreferencesViewModel) {
      self.serviceManager = serviceManager
      self.preferencesModel = preferencesModel
    }

    func start() {
      NSApplication.shared.setActivationPolicy(.regular)
      showMainWindow()
      observeEditorDraft()
      installSettingsShortcut()
      NSApplication.shared.activate()
    }

    private func showMainWindow() {
      let root = ContentView(serviceManager: serviceManager, preferencesModel: preferencesModel)
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

    /// Mirrors the production editor `Window` scene: open an AppKit window hosting
    /// the editor whenever a draft exists, and close it when the draft clears
    /// (which the view model only does on a successful save or a cancel).
    private func observeEditorDraft() {
      // Production keys editor presentation off `editorPresentationID` (via the
      // SwiftUI openWindow/dismissWindow path, gated off under test in
      // ContentView); the harness keys off `editorDraft` instead, so the SwiftUI
      // scene-presentation path itself is not exercised by these tests. The weak
      // capture is on the onChange closure so the pending Observation
      // registration does not strongly retain the coordinator.
      withObservationTracking {
        _ = preferencesModel.editorDraft
      } onChange: { [weak self] in
        Task { @MainActor in
          self?.syncEditorWindow()
          self?.observeEditorDraft()
        }
      }
    }

    private func syncEditorWindow() {
      if preferencesModel.editorDraft != nil {
        guard editorWindow == nil else {
          return
        }
        let controller = NSHostingController(
          rootView: BindingEditorWindowRoot(model: preferencesModel))
        controller.sceneBridgingOptions = [.title]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 600, height: 680))
        window.center()
        // Hide the main window while editing so the editor is the unambiguous key
        // window: the NSView shortcut recorder only receives synthesized keys when
        // its window is key, and two visible windows make that racy under XCUITest.
        mainWindow?.orderOut(nil)
        window.makeKeyAndOrderFront(nil)
        editorWindow = window
      } else {
        editorWindow?.close()
        editorWindow = nil
        mainWindow?.makeKeyAndOrderFront(nil)
      }
    }

    /// The Settings scene is also a SwiftUI scene, so intercept its ⌘, shortcut
    /// and host `SettingsView` in an AppKit window instead.
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
        rootView: SettingsView(serviceManager: serviceManager, preferencesModel: preferencesModel))
      let window = NSWindow(contentViewController: controller)
      window.styleMask = [.titled, .closable]
      window.setContentSize(NSSize(width: 520, height: 540))
      window.title = "Settings"
      window.center()
      window.makeKeyAndOrderFront(nil)
      settingsWindow = window
    }
  }

  /// Debug-only injection seam for the XCUITest suite (`UITests/`).
  ///
  /// The entire harness is compiled `#if DEBUG`, so it is physically absent from
  /// Release/archive builds. It additionally activates only when the app is
  /// launched with the `-summondUITests` argument, which `XCUIApplication` sets
  /// before `launch()`. Normal Debug launches keep the real dependencies. This
  /// lets UI tests run without registering real `SMAppService` login items,
  /// without hitting real XPC, without touching the shared defaults suite, and
  /// against a deterministic app catalog.
  enum UITestHarness {
    /// True when the process was launched by the UI-test runner.
    static var isActive: Bool {
      ProcessInfo.processInfo.arguments.contains("-summondUITests")
    }

    /// The dependencies built for the running UI test, shared with the AppKit
    /// window coordinator (which cannot reach the App struct's `@State`).
    @MainActor static var sharedDependencies: (ServiceManager, PreferencesViewModel)?

    /// A shortcut to pre-fill into a newly-added binding draft, parsed from
    /// `SUMMOND_UITEST_DRAFT_SHORTCUT` (e.g. "cmd+f"). Driving the real `NSView`
    /// recorder via synthesized keys is inherently flaky under XCUITest in the
    /// headless VM; tests whose subject is NOT shortcut recording use this to set
    /// the shortcut deterministically. The recorder itself is covered by a
    /// dedicated test that types a real key.
    static var prefilledDraftShortcut: ShortcutDraft? {
      guard let raw = env("SUMMOND_UITEST_DRAFT_SHORTCUT"), !raw.isEmpty else {
        return nil
      }
      var parts = raw.split(separator: "+").map(String.init)
      guard let key = parts.popLast() else {
        return nil
      }
      return ShortcutDraft(key: key, mods: parts)
    }

    /// Builds the app's two root dependencies with fakes wired in, mirroring the
    /// production wiring in `SummondApp.init()` (including the agent-status
    /// reload callback).
    @MainActor
    static func makeDependencies() -> (ServiceManager, PreferencesViewModel) {
      let agentClient = UITestAgentClient(
        accessibilityGranted: flag("SUMMOND_UITEST_ACCESSIBILITY", default: true),
        inputMonitoringGranted: flag("SUMMOND_UITEST_INPUT_MONITORING", default: true),
        reloadFails: env("SUMMOND_UITEST_RELOAD") == "fail"
      )

      let serviceEnabled = flag("SUMMOND_UITEST_SERVICE", default: true)
      let serviceManager = ServiceManager(
        agentService: UITestLoginItemService(status: serviceEnabled ? .enabled : .notRegistered),
        statusItemService: UITestLoginItemService(status: .notRegistered),
        agentClient: agentClient
      )

      let preferencesModel = PreferencesViewModel(
        store: makeStore(),
        agentClient: agentClient,
        appCatalog: UITestAppCatalog()
      )
      preferencesModel.onAgentStatusReloaded = { [weak serviceManager] status in
        serviceManager?.acceptReloadedStatus(status)
      }

      sharedDependencies = (serviceManager, preferencesModel)
      return (serviceManager, preferencesModel)
    }

    // MARK: - Store seeding

    private static func makeStore() -> any ConfigurationStore {
      // An ephemeral real UserDefaults suite exercises the *shipped* store
      // (UserDefaultsConfigurationStore + cfprefsd round-trip) so a relaunch test
      // can prove genuine cross-launch persistence without polluting the real
      // shared suite. The VM is disposable, so the throwaway suite is harmless.
      if let suite = env("SUMMOND_UITEST_SUITE"),
        let store = UserDefaultsConfigurationStore(suiteName: suite)
      {
        return store
      }
      return makeInMemoryStore()
    }

    private static func makeInMemoryStore() -> InMemoryConfigurationStore {
      switch env("SUMMOND_UITEST_SEED") {
      case "corrupt":
        // Undecodable bytes drive ConfigurationStore.load() to .corrupt, which
        // surfaces the recoverable-error banner + reset flow.
        return InMemoryConfigurationStore(data: Data("not-valid-summond-json".utf8))
      case "one":
        return seededStore(bindings: [binding("com.apple.Safari", key: "f", mode: .launch)])
      case "two":
        return seededStore(bindings: [
          binding("com.apple.Safari", key: "f", mode: .launch),
          binding("com.apple.Terminal", key: "t", mode: .launch),
        ])
      default:
        return InMemoryConfigurationStore()
      }
    }

    private static func seededStore(bindings: [StoredBinding]) -> InMemoryConfigurationStore {
      let store = InMemoryConfigurationStore()
      try? store.save(SummondConfigurationV1(bindings: bindings))
      return store
    }

    private static func binding(_ bundleID: String, key: String, mode: AppOpenMode) -> StoredBinding
    {
      StoredBinding(
        shortcut: Shortcut(key: key, mods: ["cmd"]),
        // bundleID is non-empty, so AppTarget never throws here.
        target: try! AppTarget(bundleID: bundleID, mode: mode)
      )
    }

    // MARK: - Environment

    private static func env(_ key: String) -> String? {
      ProcessInfo.processInfo.environment[key]
    }

    private static func flag(_ key: String, default defaultValue: Bool) -> Bool {
      guard let value = env(key) else {
        return defaultValue
      }
      return value != "0"
    }
  }

  /// Stub agent client that reports a chosen permission/health state and never
  /// touches XPC or system settings.
  struct UITestAgentClient: AgentClientProtocol {
    let accessibilityGranted: Bool
    let inputMonitoringGranted: Bool
    var reloadFails: Bool = false

    func status() async throws -> AgentStatus { makeStatus() }

    func reloadConfiguration() async throws -> AgentStatus {
      if reloadFails {
        // Drives the "saved, but the agent did not reload" warning banner.
        throw CocoaError(.xpcConnectionInvalid)
      }
      return makeStatus()
    }

    func requestAccessibilityPrompt() {}
    func requestInputMonitoringPrompt() {}

    private func makeStatus() -> AgentStatus {
      AgentStatus(
        agentVersion: "uitest",
        accessibilityGranted: accessibilityGranted,
        inputMonitoringGranted: inputMonitoringGranted,
        tapActive: accessibilityGranted && inputMonitoringGranted,
        configState: .ok,
        bindingCount: 0,
        lastReloadError: nil
      )
    }
  }

  /// Stub login-item service that reports a fixed status and no-ops every
  /// `SMAppService` side effect.
  struct UITestLoginItemService: LoginItemServiceManaging {
    let status: ServiceRegistrationStatus
    func register() async throws {}
    func unregister() async throws {}
    func openSystemSettingsLoginItems() {}
  }

  /// Deterministic, host-independent app catalog. Display names are pinned
  /// because UI assertions (e.g. the duplicate-shortcut message) render them.
  struct UITestAppCatalog: AppDisplayResolving {
    private static let apps: [AppDisplayInfo] = [
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
      Self.apps.first { $0.bundleID == bundleID } ?? .missing(bundleID: bundleID)
    }

    @MainActor
    func identity(forApplicationURL url: URL) -> AppIdentity? {
      nil
    }

    @MainActor
    func installedApplications() async -> [AppDisplayInfo] {
      Self.apps
    }
  }
#endif
