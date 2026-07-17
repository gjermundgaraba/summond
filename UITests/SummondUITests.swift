import XCTest

/// End-to-end UI tests that drive the real Summond preferences app through
/// `XCUIApplication`. The app is launched with `-summondUITests`, which routes
/// `SummondApp.init()` to a Debug-only harness (`App/Support/UITestSupport.swift`)
/// that injects fakes for XPC, SMAppService, the app catalog, and the config
/// store — so these tests exercise the real SwiftUI views, view models, and the
/// configuration persistence path (including a real cross-launch `UserDefaults`
/// round-trip) without registering system services or depending on the host's
/// installed apps.
///
/// Coverage boundary: SwiftUI scene windows do not render under XCUITest in the
/// Tart VM, so the harness hosts the real views in AppKit windows
/// (`UITestWindowCoordinator`). Consequently the production *scene* layer is NOT
/// exercised here — `WindowGroup`/`Window`/`Settings` presentation, the
/// `SummondShortcutCommands` menu items (⌘N/⌘↩/⌦/⌘R), the `summond://` URL /
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
  /// activates (deterministic empty state + suppressed onboarding), and
  /// synthesized events reach the app (open the editor, then cancel it).
  func testSmokeLaunchRendersAndAcceptsInput() {
    let app = launch()

    XCTAssertTrue(
      app.buttons["toolbar.addShortcut"].waitForExistence(timeout: launchTimeout),
      "Main window never rendered under tart exec")
    XCTAssertTrue(app.staticTexts["No shortcuts yet"].waitForExistence(timeout: uiTimeout))

    // Onboarding must be suppressed when fully set up. Wait for a stable main
    // element first (done above), then assert absence with a bounded wait so a
    // late-appearing sheet cannot pass spuriously.
    XCTAssertFalse(
      app.buttons["onboarding.getStartedButton"].waitForExistence(timeout: 3),
      "Onboarding should be suppressed when setup is complete")

    // Event injection: open the editor window and dismiss it.
    app.buttons["toolbar.addShortcut"].click()
    let recorder = app.buttons["editor.shortcutRecorder"]
    XCTAssertTrue(recorder.waitForExistence(timeout: uiTimeout), "Editor did not open on Add")
    app.buttons["editor.cancelButton"].click()
    XCTAssertTrue(
      waitForDisappearance(recorder, timeout: uiTimeout), "Editor did not close on Cancel")
  }

  // MARK: - Add / record / persist

  /// Full create flow through the real `NSView` shortcut recorder and app picker,
  /// asserting the binding is rendered in the list afterwards.
  func testAddBindingWithRealRecorderShowsRow() {
    let app = launch()
    XCTAssertTrue(app.buttons["toolbar.addShortcut"].waitForExistence(timeout: launchTimeout))

    app.buttons["toolbar.addShortcut"].click()
    recordCommandShortcut(app, key: "j", expected: "⌘J")
    selectAppInPicker(app, bundleID: "com.apple.Safari")

    let save = app.buttons["editor.saveButton"]
    XCTAssertTrue(save.waitForExistence(timeout: uiTimeout))
    XCTAssertTrue(save.isEnabled, "Save should be enabled once a shortcut and app are set")
    save.click()

    XCTAssertTrue(
      app.staticTexts["Shortcut ⌘J"].waitForExistence(timeout: uiTimeout),
      "Saved binding row was not shown")
    XCTAssertTrue(app.staticTexts["Safari"].waitForExistence(timeout: uiTimeout))
  }

  // MARK: - Validation

  /// A second binding that reuses an existing shortcut surfaces the named
  /// duplicate message and keeps Save disabled.
  func testDuplicateShortcutBlocksSave() {
    // ⌘F duplicates the seeded Safari binding. The shortcut is pre-filled (the
    // recorder itself is covered by testAddBindingWithRealRecorderShowsRow).
    let app = launch(seed: "one", draftShortcut: "cmd+f")
    XCTAssertTrue(app.buttons["toolbar.addShortcut"].waitForExistence(timeout: launchTimeout))

    app.buttons["toolbar.addShortcut"].click()
    selectAppInPicker(app, bundleID: "com.apple.Terminal")

    XCTAssertTrue(
      staticTextContaining(app, "Duplicates ⌘F for Safari").waitForExistence(timeout: uiTimeout),
      "Duplicate-shortcut message not shown")
    XCTAssertFalse(
      app.buttons["editor.saveButton"].isEnabled, "Save must stay disabled for a duplicate")
  }

  // MARK: - Edit

  /// Editing an existing binding's open-mode persists and re-renders the row.
  func testEditChangesOpenMode() {
    let app = launch(seed: "one")  // Safari, Switch to It mode

    // Open the editor via the row's context-menu Edit. The row also supports
    // double-click-to-edit, but XCUITest's synthesized double-click does not
    // reliably register as clickCount == 2 for the local mouse monitor that
    // drives it, so the context menu is the deterministic trigger here.
    let safariCell = app.cells.containing(.staticText, identifier: "bindingRow.com.apple.Safari")
      .firstMatch
    XCTAssertTrue(safariCell.waitForExistence(timeout: launchTimeout), "Safari row not found")
    safariCell.rightClick()
    let editItem = app.menuItems["bindingRow.edit"].firstMatch
    XCTAssertTrue(editItem.waitForExistence(timeout: uiTimeout), "Edit menu item not shown")
    editItem.click()

    let modeChoices = app.descendants(matching: .any)["editor.modeChoices"]
    XCTAssertTrue(
      modeChoices.waitForExistence(timeout: uiTimeout), "Editor did not open for edit")

    app.buttons["editor.mode.move"].click()
    app.buttons["editor.saveButton"].click()

    // The editor also renders the mode title, so first prove the editor closed —
    // which only happens on a successful persist — before asserting the row
    // updated; otherwise the assertion could match the still-open editor's label.
    XCTAssertTrue(
      waitForDisappearance(modeChoices, timeout: uiTimeout), "Editor did not close after Save")
    XCTAssertTrue(
      staticTextContaining(app, "Move Here").waitForExistence(timeout: uiTimeout),
      "Row did not reflect the new Move mode")
  }

  // MARK: - Delete

  /// Deleting the selected binding removes only that row.
  func testDeleteRemovesOnlySelectedRow() {
    let app = launch(seed: "two")  // Safari ⌘F + Terminal ⌘T
    XCTAssertTrue(app.staticTexts["Shortcut ⌘F"].waitForExistence(timeout: launchTimeout))
    XCTAssertTrue(app.staticTexts["Shortcut ⌘T"].waitForExistence(timeout: uiTimeout))

    // Delete via the row's context menu (no List-selection dependency).
    let safariCell = app.cells.containing(.staticText, identifier: "bindingRow.com.apple.Safari")
      .firstMatch
    XCTAssertTrue(safariCell.waitForExistence(timeout: uiTimeout), "Safari row not found")
    safariCell.rightClick()
    let deleteItem = app.menuItems["bindingRow.delete"].firstMatch
    XCTAssertTrue(deleteItem.waitForExistence(timeout: uiTimeout), "Delete menu item not shown")
    deleteItem.click()

    XCTAssertTrue(
      waitForDisappearance(app.staticTexts["Shortcut ⌘F"], timeout: uiTimeout),
      "Deleted row should disappear")
    XCTAssertTrue(app.staticTexts["Shortcut ⌘T"].exists, "Unrelated row should remain")
  }

  // MARK: - Corrupt config recovery

  /// A corrupt stored configuration surfaces the recovery banner; resetting it
  /// returns the app to a clean empty state.
  func testCorruptConfigurationResets() {
    let app = launch(seed: "corrupt")
    // The reset button is shown only for a corrupt configuration banner.
    let reset = app.buttons["banner.resetButton"]
    XCTAssertTrue(reset.waitForExistence(timeout: launchTimeout), "Corrupt-config banner not shown")
    XCTAssertTrue(
      staticTextContaining(app, "Configuration could not be loaded").waitForExistence(timeout: 5),
      "Corrupt-config banner title not shown")

    reset.click()

    // The confirmation renders as a sheet; scope to it so the query doesn't match
    // the Touch Bar's mirrored copy of the button.
    let confirm = app.sheets.buttons["Reset to Empty Configuration"].firstMatch
    XCTAssertTrue(confirm.waitForExistence(timeout: uiTimeout), "Reset confirmation not shown")
    confirm.click()

    XCTAssertTrue(
      app.staticTexts["No shortcuts yet"].waitForExistence(timeout: uiTimeout),
      "App did not return to empty state after reset")
  }

  // MARK: - Settings

  /// The verbose-logging toggle round-trips through the view model both ways.
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
      app.staticTexts["Shortcut ⌘J"].waitForExistence(timeout: uiTimeout),
      "Binding should still be saved when the agent reload fails")
    XCTAssertTrue(
      staticTextContaining(app, "Changes were saved, but the agent did not reload")
        .waitForExistence(timeout: uiTimeout),
      "Reload-failure warning banner not shown")
  }

  // MARK: - Onboarding gating

  /// When a hard requirement is missing, onboarding presents and advances to the
  /// unmet step.
  func testOnboardingPresentsWhenAccessibilityMissing() {
    let app = launch(accessibility: false, onboarded: false)

    let getStarted = app.buttons["onboarding.getStartedButton"]
    XCTAssertTrue(getStarted.waitForExistence(timeout: launchTimeout), "Onboarding did not present")
    getStarted.click()

    // Service is satisfied, so onboarding skips to the unmet Accessibility step.
    // We assert its action button exists but never tap it (it opens System Settings).
    XCTAssertTrue(
      app.buttons["onboarding.openAccessibilitySettingsButton"].waitForExistence(timeout: 15),
      "Onboarding did not advance to the Accessibility step")
  }

  /// The completion screen should not offer to add a first shortcut once the
  /// user already has bindings.
  func testCompletedOnboardingWithExistingBindingHidesFirstShortcutAction() {
    let app = launch(seed: "one", onboarded: false)

    XCTAssertTrue(
      app.staticTexts["Shortcut ⌘F"].waitForExistence(timeout: launchTimeout),
      "Seeded binding row was not shown")
    let getStarted = app.buttons["onboarding.getStartedButton"]
    XCTAssertTrue(getStarted.waitForExistence(timeout: uiTimeout), "Onboarding did not present")
    getStarted.click()

    XCTAssertTrue(
      staticTextContaining(app, "You're all set").waitForExistence(timeout: uiTimeout),
      "Onboarding did not reach the completion step")
    XCTAssertFalse(
      app.buttons["Add Your First Shortcut"].waitForExistence(timeout: 3),
      "First-shortcut action should be hidden when a binding already exists")
  }

  /// Dismissing completed onboarding with Done should stay dismissed instead of
  /// immediately presenting the same completion sheet again.
  func testCompletedOnboardingDoneStaysDismissed() {
    let app = launch(seed: "one", onboarded: false)

    XCTAssertTrue(
      app.staticTexts["Shortcut ⌘F"].waitForExistence(timeout: launchTimeout),
      "Seeded binding row was not shown")
    let getStarted = app.buttons["onboarding.getStartedButton"]
    XCTAssertTrue(getStarted.waitForExistence(timeout: uiTimeout), "Onboarding did not present")
    getStarted.click()

    let completionTitle = staticTextContaining(app, "You're all set")
    XCTAssertTrue(
      completionTitle.waitForExistence(timeout: uiTimeout),
      "Onboarding did not reach the completion step")
    app.buttons["Done"].click()

    XCTAssertTrue(
      waitForDisappearance(completionTitle, timeout: uiTimeout),
      "Onboarding completion sheet did not dismiss")
    XCTAssertFalse(
      completionTitle.waitForExistence(timeout: 3),
      "Onboarding completion sheet should stay dismissed after Done")
    XCTAssertFalse(
      staticTextContaining(app, "Setup needed").waitForExistence(timeout: 3),
      "Setup banner should not return after completed onboarding is dismissed")
  }

  // MARK: - Real-store persistence across relaunch

  /// Backs the app with the *shipped* `UserDefaultsConfigurationStore` against an
  /// ephemeral throwaway suite, adds a binding, relaunches, and asserts it
  /// survived — proving genuine cross-launch persistence (not just in-session
  /// state).
  func testBindingPersistsAcrossRelaunch() {
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
    XCTAssertTrue(app.staticTexts["Shortcut ⌘J"].waitForExistence(timeout: uiTimeout))

    app.terminate()
    app.launch()  // same suite -> the real store must reload the binding

    XCTAssertTrue(
      app.staticTexts["Shortcut ⌘J"].waitForExistence(timeout: launchTimeout),
      "Binding did not survive a relaunch through the real configuration store")
  }

  // MARK: - Launch helpers

  private func configuredApp(
    seed: String? = nil,
    accessibility: Bool = true,
    inputMonitoring: Bool = true,
    serviceEnabled: Bool = true,
    onboarded: Bool = true,
    reloadFails: Bool = false,
    draftShortcut: String? = nil,
    suite: String? = nil
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-summondUITests", "-hasCompletedOnboarding", onboarded ? "1" : "0"]
    var environment: [String: String] = [
      "SUMMOND_UITEST_ACCESSIBILITY": accessibility ? "1" : "0",
      "SUMMOND_UITEST_INPUT_MONITORING": inputMonitoring ? "1" : "0",
      "SUMMOND_UITEST_SERVICE": serviceEnabled ? "1" : "0",
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
    app.launchEnvironment = environment
    return app
  }

  @discardableResult
  private func launch(
    seed: String? = nil,
    accessibility: Bool = true,
    inputMonitoring: Bool = true,
    serviceEnabled: Bool = true,
    onboarded: Bool = true,
    reloadFails: Bool = false,
    draftShortcut: String? = nil
  ) -> XCUIApplication {
    let app = configuredApp(
      seed: seed,
      accessibility: accessibility,
      inputMonitoring: inputMonitoring,
      serviceEnabled: serviceEnabled,
      onboarded: onboarded,
      reloadFails: reloadFails,
      draftShortcut: draftShortcut
    )
    app.launch()
    return app
  }

  // MARK: - Interaction helpers

  /// Records a Command+<key> shortcut by clicking the recorder and synthesizing
  /// the real key event through `ShortcutRecorderNSView`. Retries because the
  /// click -> first-responder -> isRecording state hop is asynchronous.
  private func recordCommandShortcut(_ app: XCUIApplication, key: String, expected: String) {
    let recorder = app.buttons["editor.shortcutRecorder"].firstMatch
    XCTAssertTrue(recorder.waitForExistence(timeout: uiTimeout), "Shortcut recorder not found")

    // The NSView's `isRecording` flag is set via a SwiftUI binding round-trip
    // after the click, so wait until the recorder reports it is recording before
    // synthesizing the key; retry in case the key lands too early or recording
    // was cancelled. (The coordinator hides the main window during editing so the
    // editor is the key window that receives the synthesized key.)
    for _ in 0..<8 {
      if (recorder.value as? String) == expected {
        return
      }
      recorder.click()
      _ = waitForValue(recorder, "recording", timeout: 3)
      app.typeKey(key, modifierFlags: .command)
      _ = waitForValue(recorder, expected, timeout: 2)
    }
    XCTAssertEqual(recorder.value as? String, expected, "Recorder did not capture \(expected)")
  }

  private func selectAppInPicker(_ app: XCUIApplication, bundleID: String) {
    let row = app.buttons["appRow.\(bundleID)"]
    XCTAssertTrue(row.waitForExistence(timeout: uiTimeout), "App \(bundleID) not in picker")
    row.click()
  }

  // MARK: - Query helpers

  private func staticTextContaining(_ app: XCUIApplication, _ text: String) -> XCUIElement {
    // SwiftUI `Text` exposes its string as the AX value, not the label.
    app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
    ).firstMatch
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
