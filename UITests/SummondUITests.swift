import XCTest

/// End-to-end UI tests that drive the real Summond app through
/// `XCUIApplication`. The app is launched with `-summondUITests`, which routes
/// `SummondApp.init()` to a Debug-only harness (`App/Support/UITestSupport.swift`)
/// that injects fakes for XPC, SMAppService, the app catalog, and the config
/// store — so these tests exercise the real SwiftUI views, app model, and the
/// configuration persistence path (including a real cross-launch `UserDefaults`
/// round-trip) without registering system services or depending on the host's
/// installed apps.
///
/// Coverage boundary: SwiftUI scene windows do not render under XCUITest in the
/// Tart VM, so the harness hosts the real views in AppKit windows
/// (`UITestWindowCoordinator`). Consequently the production *scene* layer is NOT
/// exercised here — `WindowGroup`/`Settings` presentation, the shortcut menu
/// items (⌘N/⌘↩/⌦), the `summond://` URL /
/// `onOpenURL` deep link, `defaultWindowPlacement`/`restorationBehavior`, and
/// `scenePhase` reactivation remain manual-test-only.
///
/// These tests are intended to run only inside the Tart VM (`make test-tart`),
/// which runs `make test ui-test`; they are not part of the host `make test`.
final class SummondUITests: XCTestCase {
  /// Cold-boot the app + WindowServer handshake can be slow on a fresh VM clone.
  private let launchTimeout: TimeInterval = 60
  private let uiTimeout: TimeInterval = 10

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  // MARK: - Canary

  /// Proves, in one test, the three capabilities everything else depends on:
  /// the app launches and renders its window under `tart exec`, the harness
  /// activates (deterministic empty state + suppressed Setup Assistant), and
  /// synthesized events reach the app (open the editor, then cancel it).
  func testSmokeLaunchRendersAndAcceptsInput() {
    let app = launch()

    XCTAssertTrue(
      app.buttons["toolbar.addShortcut"].waitForExistence(timeout: launchTimeout),
      "Main window never rendered under tart exec")
    XCTAssertTrue(app.staticTexts["No Shortcuts"].waitForExistence(timeout: uiTimeout))

    // The Setup Assistant must be suppressed after its first presentation. Wait for a stable main
    // element first (done above), then assert absence with a bounded wait so a
    // late-appearing sheet cannot pass spuriously.
    XCTAssertFalse(
      app.buttons["setup.setUpLaterButton"].waitForExistence(timeout: 3),
      "Setup Assistant should be suppressed after its initial presentation")

    // Event injection: open the editor sheet and dismiss it.
    app.buttons["toolbar.addShortcut"].click()
    let recorder = app.buttons["editor.shortcutRecorder"]
    XCTAssertTrue(recorder.waitForExistence(timeout: uiTimeout), "Editor did not open on Add")
    app.buttons["editor.cancelButton"].click()
    XCTAssertTrue(
      waitForDisappearance(recorder, timeout: uiTimeout), "Editor did not close on Cancel")
  }

  // MARK: - Add / record / persist

  /// Full create flow through the real `NSView` shortcut recorder and app picker,
  /// asserting the shortcut is rendered in the list afterwards.
  func testAddShortcutWithRealRecorderShowsRow() {
    let app = launch()
    XCTAssertTrue(app.buttons["toolbar.addShortcut"].waitForExistence(timeout: launchTimeout))

    app.buttons["toolbar.addShortcut"].click()
    recordCommandShortcut(app, key: "j", expectedAccessibilityValue: "Command J")
    selectAppInPicker(app, bundleID: "com.apple.Safari")

    let save = app.buttons["editor.saveButton"]
    XCTAssertTrue(save.waitForExistence(timeout: uiTimeout))
    XCTAssertTrue(save.isEnabled, "Save should be enabled once a shortcut and app are set")
    save.click()

    let safariRow = shortcutRow(app, bundleID: "com.apple.Safari")
    XCTAssertTrue(
      safariRow.waitForExistence(timeout: uiTimeout), "Saved shortcut row was not shown")
    XCTAssertTrue(
      (safariRow.value as? String)?.contains("Safari") == true,
      "Saved row did not identify Safari")
  }

  // MARK: - Validation

  /// A second shortcut that reuses an existing key combination surfaces the named
  /// duplicate message and keeps Save disabled.
  func testDuplicateShortcutBlocksSave() {
    // ⌘F duplicates the seeded Safari shortcut. The shortcut is pre-filled (the
    // recorder itself is covered by testAddShortcutWithRealRecorderShowsRow).
    let app = launch(seed: "one", draftShortcut: "cmd+f")
    XCTAssertTrue(app.buttons["toolbar.addShortcut"].waitForExistence(timeout: launchTimeout))

    app.buttons["toolbar.addShortcut"].click()
    selectAppInPicker(app, bundleID: "com.apple.Terminal")

    XCTAssertTrue(
      staticTextContaining(app, "⌘F already opens Safari").waitForExistence(timeout: uiTimeout),
      "Duplicate-shortcut message not shown")
    XCTAssertFalse(
      app.buttons["editor.saveButton"].isEnabled, "Save must stay disabled for a duplicate")
  }

  // MARK: - Edit

  /// Editing an existing shortcut's open-mode persists and re-renders the row.
  func testEditChangesOpenMode() {
    let app = launch(seed: "one")  // Safari, Switch to It mode

    // Open the editor via the row's context-menu Edit. The row also supports
    // double-click-to-edit, but XCUITest's synthesized double-click does not
    // reliably register as clickCount == 2 for the local mouse monitor that
    // drives it, so the context menu is the deterministic trigger here.
    let safariRow = shortcutRow(app, bundleID: "com.apple.Safari")
    XCTAssertTrue(safariRow.waitForExistence(timeout: launchTimeout), "Safari row not found")
    safariRow.rightClick()
    let editItem = app.menuItems["shortcutRow.edit"].firstMatch
    XCTAssertTrue(editItem.waitForExistence(timeout: uiTimeout), "Edit menu item not shown")
    editItem.click()

    let behaviorPicker = app.descendants(matching: .any)["editor.behaviorPicker"]
    XCTAssertTrue(
      behaviorPicker.waitForExistence(timeout: uiTimeout), "Editor did not open for edit")

    let moveMode = app.radioButtons["Move Here"].firstMatch
    XCTAssertTrue(moveMode.waitForExistence(timeout: uiTimeout), "Move mode was not shown")
    moveMode.click()
    app.buttons["editor.saveButton"].click()

    // The editor also renders the mode title, so first prove the editor closed —
    // which only happens on a successful persist — before asserting the row
    // updated; otherwise the assertion could match the still-open editor's label.
    XCTAssertTrue(
      waitForDisappearance(behaviorPicker, timeout: uiTimeout), "Editor did not close after Save")
    XCTAssertTrue(
      waitForValueContaining(safariRow, "Move Here", timeout: uiTimeout),
      "Row did not reflect the new Move mode")
  }

  // MARK: - Delete

  /// Deleting the selected shortcut removes only that row.
  func testDeleteRemovesOnlySelectedRow() {
    let app = launch(seed: "two")  // Safari ⌘F + Terminal ⌘T
    let safariRow = shortcutRow(app, bundleID: "com.apple.Safari")
    let terminalRow = shortcutRow(app, bundleID: "com.apple.Terminal")
    XCTAssertTrue(safariRow.waitForExistence(timeout: launchTimeout))
    XCTAssertTrue(terminalRow.waitForExistence(timeout: uiTimeout))

    // Delete via the row's context menu (no List-selection dependency).
    safariRow.rightClick()
    let deleteItem = app.menuItems["shortcutRow.delete"].firstMatch
    XCTAssertTrue(deleteItem.waitForExistence(timeout: uiTimeout), "Delete menu item not shown")
    deleteItem.click()

    let confirm = app.sheets.buttons["Delete Shortcut"].firstMatch
    XCTAssertTrue(confirm.waitForExistence(timeout: uiTimeout), "Delete confirmation not shown")
    confirm.click()

    XCTAssertTrue(
      waitForDisappearance(safariRow, timeout: uiTimeout),
      "Deleted row should disappear")
    XCTAssertTrue(terminalRow.exists, "Unrelated row should remain")
  }

  // MARK: - Corrupt config recovery

  /// A corrupt stored configuration surfaces the recovery banner; resetting it
  /// returns the app to a clean empty state.
  func testCorruptConfigurationResets() {
    let app = launch(seed: "corrupt")
    // The reset button is shown only for a corrupt configuration banner.
    let reset = app.buttons["configuration.resetButton"]
    XCTAssertTrue(reset.waitForExistence(timeout: launchTimeout), "Corrupt-config banner not shown")
    XCTAssertTrue(
      staticTextContaining(app, "Configuration Could Not Be Loaded").waitForExistence(timeout: 5),
      "Corrupt-config banner title not shown")

    reset.click()

    // The confirmation renders as a sheet; scope to it so the query doesn't match
    // the Touch Bar's mirrored copy of the button.
    let confirm = app.sheets.buttons["Reset to Empty Configuration"].firstMatch
    XCTAssertTrue(confirm.waitForExistence(timeout: uiTimeout), "Reset confirmation not shown")
    confirm.click()

    XCTAssertTrue(
      app.staticTexts["No Shortcuts"].waitForExistence(timeout: uiTimeout),
      "App did not return to empty state after reset")
  }

  // MARK: - Settings

  /// The verbose-logging toggle round-trips through the app model both ways.
  func testVerboseLoggingToggleRoundTrips() {
    let app = launch()
    XCTAssertTrue(app.buttons["toolbar.addShortcut"].waitForExistence(timeout: launchTimeout))

    app.typeKey(",", modifierFlags: .command)  // open Settings

    let toggle = app.descendants(matching: .any)["settings.verboseLogging"]
    XCTAssertTrue(toggle.waitForExistence(timeout: uiTimeout), "Settings toggle never appeared")

    // The toggle reflects the persisted draft, which updates asynchronously after
    // each click, so wait for the value to settle rather than reading it instantly.
    XCTAssertTrue(waitForToggle(toggle, on: false), "Verbose logging should start off")
    toggle.click()
    XCTAssertTrue(waitForToggle(toggle, on: true), "Toggling on should enable verbose logging")
    toggle.click()
    XCTAssertTrue(waitForToggle(toggle, on: false), "Toggling off should disable verbose logging")
  }

  // MARK: - Reload failure is non-fatal

  /// When the agent reload fails, the save still persists locally and a
  /// non-blocking warning banner explains the failure.
  func testReloadFailureStillSavesAndWarns() {
    let app = launch(reloadFails: true, draftShortcut: "cmd+j")
    XCTAssertTrue(app.buttons["toolbar.addShortcut"].waitForExistence(timeout: launchTimeout))

    app.buttons["toolbar.addShortcut"].click()
    selectAppInPicker(app, bundleID: "com.apple.Safari")
    app.buttons["editor.saveButton"].click()

    XCTAssertTrue(
      shortcutRow(app, bundleID: "com.apple.Safari").waitForExistence(timeout: uiTimeout),
      "Shortcut should still be saved when the agent reload fails")
    XCTAssertTrue(
      staticTextContaining(app, "Changes Saved, Reload Failed")
        .waitForExistence(timeout: uiTimeout),
      "Reload-failure warning banner not shown")
  }

  // MARK: - Setup Assistant

  /// When a hard requirement is missing, the Setup Assistant presents a checklist
  /// with the relevant remediation action.
  func testSetupAssistantPresentsWhenAccessibilityMissing() {
    let app = launch(accessibility: false, setupPresented: false)

    XCTAssertTrue(
      staticTextContaining(app, "Set up Summond").waitForExistence(timeout: launchTimeout),
      "Setup Assistant did not present")
    // We assert the action exists but never tap it because it opens System Settings.
    XCTAssertTrue(
      app.buttons["setup.openAccessibilitySettingsButton"]
        .waitForExistence(timeout: uiTimeout),
      "Accessibility remediation was not shown")
  }

  /// Exercises the real PermissionFlow surface and System Settings application
  /// while keeping agent status deterministic through the UI-test harness.
  func testAccessibilityPermissionFlowOpensSettingsForEmbeddedAgent() {
    let app = launch(
      accessibility: false,
      setupPresented: false,
      permissionFlow: true
    )

    let action = app.buttons["setup.openAccessibilitySettingsButton"]
    XCTAssertTrue(action.waitForExistence(timeout: launchTimeout))
    action.click()

    let settings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
    XCTAssertTrue(
      settings.wait(for: .runningForeground, timeout: launchTimeout),
      "System Settings did not become foreground")
    XCTAssertTrue(
      app.staticTexts["SummondAgent"].waitForExistence(timeout: uiTimeout),
      "PermissionFlow did not offer the embedded agent app")

    XCTAssertTrue(
      settings.staticTexts["Accessibility"].waitForExistence(timeout: uiTimeout),
      "PermissionFlow did not open the Accessibility settings pane")
  }

  /// The completion screen should not offer to add a first shortcut once the
  /// user already has shortcuts.
  func testReadySetupAssistantWithExistingShortcutHidesFirstShortcutAction() {
    let app = launch(seed: "one", setupPresented: false)

    XCTAssertTrue(
      staticTextContaining(app, "Setup complete").waitForExistence(timeout: launchTimeout),
      "Ready Setup Assistant was not shown")
    XCTAssertFalse(
      app.buttons["Add Your First Shortcut"].waitForExistence(timeout: 3),
      "First-shortcut action should be hidden when a shortcut already exists")
  }

  /// Dismissing the ready checklist with Done should stay dismissed instead of
  /// immediately presenting the same sheet again.
  func testReadySetupAssistantDoneStaysDismissed() {
    let app = launch(seed: "one", setupPresented: false)

    let completionTitle = staticTextContaining(app, "Setup complete")
    XCTAssertTrue(
      completionTitle.waitForExistence(timeout: launchTimeout),
      "Ready Setup Assistant was not shown")
    app.buttons["Done"].click()

    XCTAssertTrue(
      waitForDisappearance(completionTitle, timeout: uiTimeout),
      "Setup Assistant did not dismiss")
    XCTAssertFalse(
      completionTitle.waitForExistence(timeout: 3),
      "Setup Assistant should stay dismissed after Done")
    XCTAssertFalse(
      staticTextContaining(app, "Finish Setting Up Summond").waitForExistence(timeout: 3),
      "Setup banner should not appear when requirements are satisfied")
  }

  // MARK: - Real-store persistence across relaunch

  /// Backs the app with the *shipped* `UserDefaultsConfigurationStore` against an
  /// ephemeral throwaway suite, adds a shortcut, relaunches, and asserts it
  /// survived — proving genuine cross-launch persistence (not just in-session
  /// state).
  func testShortcutPersistsAcrossRelaunch() {
    let suite = "net.garaba.summond.uitest.\(UUID().uuidString)"
    addTeardownBlock {
      UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    let app = configuredApp(draftShortcut: "cmd+j", suite: suite)
    app.launch()
    XCTAssertTrue(app.buttons["toolbar.addShortcut"].waitForExistence(timeout: launchTimeout))

    app.buttons["toolbar.addShortcut"].click()
    selectAppInPicker(app, bundleID: "com.apple.Safari")
    app.buttons["editor.saveButton"].click()
    XCTAssertTrue(
      shortcutRow(app, bundleID: "com.apple.Safari").waitForExistence(timeout: uiTimeout))

    app.terminate()
    app.launch()  // same suite -> the real store must reload the shortcut

    XCTAssertTrue(
      shortcutRow(app, bundleID: "com.apple.Safari").waitForExistence(timeout: launchTimeout),
      "Shortcut did not survive a relaunch through the real configuration store")
  }

  // MARK: - Launch helpers

  private func configuredApp(
    seed: String? = nil,
    accessibility: Bool = true,
    setupPresented: Bool = true,
    reloadFails: Bool = false,
    draftShortcut: String? = nil,
    suite: String? = nil,
    permissionFlow: Bool = false
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "-summondUITests", "-hasPresentedInitialSetup", setupPresented ? "1" : "0",
    ]
    var environment: [String: String] = [
      "SUMMOND_UITEST_ACCESSIBILITY": accessibility ? "1" : "0"
    ]
    if let seed {
      environment["SUMMOND_UITEST_SEED"] = seed
    }
    if reloadFails {
      environment["SUMMOND_UITEST_RELOAD"] = "fail"
    }
    if let draftShortcut {
      environment["SUMMOND_UITEST_DRAFT_SHORTCUT"] = draftShortcut
    }
    if let suite {
      environment["SUMMOND_UITEST_SUITE"] = suite
    }
    if permissionFlow {
      environment["SUMMOND_UITEST_PERMISSION_FLOW"] = "1"
    }
    app.launchEnvironment = environment
    return app
  }

  @discardableResult
  private func launch(
    seed: String? = nil,
    accessibility: Bool = true,
    setupPresented: Bool = true,
    reloadFails: Bool = false,
    draftShortcut: String? = nil,
    permissionFlow: Bool = false
  ) -> XCUIApplication {
    let app = configuredApp(
      seed: seed,
      accessibility: accessibility,
      setupPresented: setupPresented,
      reloadFails: reloadFails,
      draftShortcut: draftShortcut,
      permissionFlow: permissionFlow
    )
    app.launch()
    return app
  }

  // MARK: - Interaction helpers

  /// Records a Command+<key> shortcut by clicking the recorder and synthesizing
  /// the real key event through `ShortcutRecorderNSView`. Retries because the
  /// click -> first-responder -> isRecording state hop is asynchronous.
  private func recordCommandShortcut(
    _ app: XCUIApplication,
    key: String,
    expectedAccessibilityValue: String
  ) {
    let recorder = app.buttons["editor.shortcutRecorder"].firstMatch
    XCTAssertTrue(recorder.waitForExistence(timeout: uiTimeout), "Shortcut recorder not found")

    // The NSView's `isRecording` flag is set via a SwiftUI binding round-trip
    // after the click, so wait until the recorder reports it is recording before
    // synthesizing the key; retry in case the key lands too early or recording
    // was cancelled.
    for _ in 0..<8 {
      if (recorder.value as? String) == expectedAccessibilityValue {
        return
      }
      recorder.click()
      _ = waitForValue(recorder, "recording", timeout: 3)
      app.typeKey(key, modifierFlags: .command)
      _ = waitForValue(recorder, expectedAccessibilityValue, timeout: 2)
    }
    XCTAssertEqual(
      recorder.value as? String,
      expectedAccessibilityValue,
      "Recorder did not capture \(expectedAccessibilityValue)")
  }

  private func selectAppInPicker(_ app: XCUIApplication, bundleID: String) {
    guard let appName = testAppName(for: bundleID) else { return }
    let row = app.descendants(matching: .any).matching(
      NSPredicate(format: "label == %@", appName)
    ).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: uiTimeout), "App \(bundleID) not in picker")
    row.click()
  }

  // MARK: - Query helpers

  private func shortcutRow(_ app: XCUIApplication, bundleID: String) -> XCUIElement {
    guard let appName = testAppName(for: bundleID) else {
      return app.descendants(matching: .any)["missing-test-app"]
    }
    return app.descendants(matching: .any).matching(
      NSPredicate(format: "value BEGINSWITH %@", "\(appName),")
    ).firstMatch
  }

  private func testAppName(for bundleID: String) -> String? {
    switch bundleID {
    case "com.apple.Safari": return "Safari"
    case "com.apple.Terminal": return "Terminal"
    case "com.apple.TextEdit": return "TextEdit"
    default:
      XCTFail("No UI-test app name for \(bundleID)")
      return nil
    }
  }

  private func staticTextContaining(_ app: XCUIApplication, _ text: String) -> XCUIElement {
    // SwiftUI `Text` exposes its string as the AX value, not the label.
    app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
    ).firstMatch
  }

  private func waitForValueContaining(
    _ element: XCUIElement,
    _ text: String,
    timeout: TimeInterval
  ) -> Bool {
    let predicate = NSPredicate(format: "value CONTAINS %@", text)
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
  }

  private func waitForValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval) -> Bool
  {
    let predicate = NSPredicate { object, _ in
      (object as? XCUIElement)?.value as? String == value
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
  }

  private func isOn(_ element: XCUIElement) -> Bool {
    switch element.value {
    case let number as Int:
      return number != 0
    case let flag as Bool:
      return flag
    case let string as String:
      return string == "1" || string.lowercased() == "true"
    default:
      return false
    }
  }

  /// Waits for a checkbox/toggle to reach the given on/off state, tolerating the
  /// async model round-trip behind it. Uses a block predicate so it works
  /// regardless of whether the AX value bridges as Int, Bool, or String.
  private func waitForToggle(_ element: XCUIElement, on: Bool, timeout: TimeInterval = 10) -> Bool {
    let predicate = NSPredicate { [weak self] object, _ in
      guard let self, let element = object as? XCUIElement else {
        return false
      }
      return self.isOn(element) == on
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
  }

  private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
    let predicate = NSPredicate(format: "exists == false")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
  }

}
