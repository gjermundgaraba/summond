import CoreGraphics
import Foundation
import Security
import Testing

@testable import KeybinddCore

@Suite("Agent status")
struct AgentStatusTests {
  @Test("JSON round trip preserves agent status")
  func jsonRoundTrip() throws {
    let status = AgentStatus(
      agentVersion: "1.2.3",
      accessibilityGranted: true,
      inputMonitoringGranted: true,
      tapActive: false,
      tapFailureReason: .installationFailed,
      configState: .invalid,
      bindingCount: 2,
      lastReloadError: "missing app",
      unresolvedBundleIDs: ["com.example.missing"]
    )

    let decoded = try AgentStatusCodec.decode(AgentStatusCodec.encode(status))

    #expect(decoded == status)
  }

  @Test("Rejects status payloads that omit required fields")
  func rejectsStatusPayloadsMissingRequiredFields() throws {
    let legacyJSON = """
      {"agentVersion":"1.0.0","accessibilityGranted":true,"tapActive":true,\
      "configState":"ok","bindingCount":3}
      """

    #expect(throws: DecodingError.self) {
      try AgentStatusCodec.decode(Data(legacyJSON.utf8))
    }
  }
}

@Suite("Service registration status")
struct ServiceRegistrationStatusTests {
  @Test("Maps mocked SMAppService states to presentation state")
  func mapsMockedStates() {
    #expect(
      ServiceRegistrationStatusMapper.presentation(for: .enabled)
        == ServiceRegistrationPresentation(
          title: "Enabled",
          canRegister: false,
          canUnregister: true,
          needsApproval: false
        )
    )
    #expect(
      ServiceRegistrationStatusMapper.presentation(for: .notRegistered)
        == ServiceRegistrationPresentation(
          title: "Not Registered",
          canRegister: true,
          canUnregister: false,
          needsApproval: false
        )
    )
    #expect(
      ServiceRegistrationStatusMapper.presentation(for: .requiresApproval).needsApproval == true
    )
    #expect(
      ServiceRegistrationStatusMapper.presentation(for: .notFound).canRegister == false
    )
  }
}

@Suite("Setup state")
struct SetupStateTests {
  @Test("Maps hard requirements to first onboarding step")
  func mapsHardRequirementsToOnboardingSteps() {
    let healthyAgent = AgentStatus(
      agentVersion: "test",
      accessibilityGranted: true,
      inputMonitoringGranted: true,
      tapActive: true,
      configState: .ok,
      bindingCount: 1,
      lastReloadError: nil
    )
    let inaccessibleAgent = AgentStatus(
      agentVersion: "test",
      accessibilityGranted: false,
      inputMonitoringGranted: false,
      tapActive: false,
      tapFailureReason: .accessibilityDenied,
      configState: .ok,
      bindingCount: 1,
      lastReloadError: nil
    )
    let noInputMonitoringAgent = AgentStatus(
      agentVersion: "test",
      accessibilityGranted: true,
      inputMonitoringGranted: false,
      tapActive: false,
      tapFailureReason: .inputMonitoringDenied,
      configState: .ok,
      bindingCount: 1,
      lastReloadError: nil
    )

    #expect(
      SetupState(serviceStatus: .enabled, agentStatus: healthyAgent)
        .hardRequirementsSatisfied
    )
    #expect(
      SetupState(serviceStatus: .enabled, agentStatus: healthyAgent)
        .firstUnmetOnboardingStep == nil
    )
    #expect(
      SetupState(serviceStatus: .enabled, agentStatus: inaccessibleAgent)
        .firstUnmetOnboardingStep == .accessibility
    )
    #expect(
      SetupState(serviceStatus: .enabled, agentStatus: noInputMonitoringAgent)
        .firstUnmetOnboardingStep == .inputMonitoring
    )
    #expect(
      SetupState(serviceStatus: .enabled, agentStatus: nil)
        .firstUnmetOnboardingStep == .backgroundService
    )
    #expect(
      !SetupState(serviceStatus: .enabled, agentStatus: nil)
        .hardRequirementsSatisfied
    )
    #expect(
      SetupState(serviceStatus: .requiresApproval, agentStatus: nil)
        .firstUnmetOnboardingStep == .backgroundService
    )
    #expect(
      SetupState(serviceStatus: .notRegistered, agentStatus: nil)
        .firstUnmetOnboardingStep == .backgroundService
    )
    #expect(
      SetupState(serviceStatus: .notFound, agentStatus: nil)
        .firstUnmetOnboardingStep == .backgroundService
    )
  }

  @Test("Auto-advances onboarding when step requirements become satisfied")
  func autoAdvancesResolvedSteps() {
    let setup = SetupState(
      serviceStatus: .enabled,
      accessibilityGranted: true,
      inputMonitoringGranted: true
    )

    #expect(setup.resolvedStep(from: .welcome) == .welcome)
    #expect(setup.resolvedStep(from: .backgroundService) == .done)
    #expect(setup.resolvedStep(from: .accessibility) == .done)
    #expect(setup.resolvedStep(from: .inputMonitoring) == .done)
    #expect(setup.resolvedStep(from: .done) == .done)

    let unreachableAgent = SetupState(
      serviceStatus: .enabled,
      agentReachable: false,
      accessibilityGranted: true,
      inputMonitoringGranted: true
    )
    #expect(unreachableAgent.resolvedStep(from: .inputMonitoring) == .backgroundService)
  }
}

@Suite("Status item presentation")
struct StatusItemPresentationTests {
  @Test("Maps a reachable agent's state matrix to menu presentation")
  func mapsReachableStateMatrix() {
    for accessibilityGranted in [true, false] {
      for inputMonitoringGranted in [true, false] {
        for configState in [
          AgentConfigurationState.ok,
          .corrupt,
          .invalid,
        ] {
          for unresolvedBundleIDs in [[], ["com.example.missing"]] {
            let agentStatus = AgentStatus(
              agentVersion: "test",
              accessibilityGranted: accessibilityGranted,
              inputMonitoringGranted: inputMonitoringGranted,
              tapActive: true,
              configState: configState,
              bindingCount: 5,
              lastReloadError: nil,
              unresolvedBundleIDs: unresolvedBundleIDs
            )

            let presentation = StatusItemPresentationMapper.presentation(agentStatus: agentStatus)

            // A reachable agent can always reload, regardless of reported state.
            #expect(presentation.canReload)

            if !accessibilityGranted {
              #expect(presentation.statusLine == "Needs Accessibility permission")
              #expect(presentation.showsWarningBadge)
            } else if !inputMonitoringGranted {
              #expect(presentation.statusLine == "Needs Input Monitoring")
              #expect(presentation.showsWarningBadge)
            } else if configState == .corrupt || configState == .invalid {
              #expect(presentation.statusLine == "Configuration problem")
              #expect(presentation.showsWarningBadge)
            } else if !unresolvedBundleIDs.isEmpty {
              #expect(presentation.statusLine == "1 app not installed")
              #expect(presentation.showsWarningBadge)
            } else {
              #expect(presentation.statusLine == "Active — 5 shortcuts")
              #expect(!presentation.showsWarningBadge)
            }
          }
        }
      }
    }
  }

  @Test("Treats an unreachable agent as not responding rather than disabled")
  func unreachableAgentIsNotResponding() {
    let presentation = StatusItemPresentationMapper.presentation(agentStatus: nil)

    #expect(presentation.statusLine == "Keybindd isn't responding")
    #expect(presentation.showsWarningBadge)
    #expect(!presentation.canReload)
  }

  @Test("Marks inactive event tap as warning")
  func marksInactiveEventTapWarning() {
    let presentation = StatusItemPresentationMapper.presentation(
      agentStatus: AgentStatus(
        agentVersion: "test",
        accessibilityGranted: true,
        inputMonitoringGranted: true,
        tapActive: false,
        tapFailureReason: .installationFailed,
        configState: .ok,
        bindingCount: 1,
        lastReloadError: nil
      )
    )

    #expect(presentation.statusLine == "Event tap unavailable")
    #expect(presentation.showsWarningBadge)
  }

  @Test("Uses singular active shortcut copy")
  func usesSingularActiveShortcutCopy() {
    let presentation = StatusItemPresentationMapper.presentation(
      agentStatus: AgentStatus(
        agentVersion: "test",
        accessibilityGranted: true,
        inputMonitoringGranted: true,
        tapActive: true,
        configState: .ok,
        bindingCount: 1,
        lastReloadError: nil
      )
    )

    #expect(presentation.statusLine == "Active — 1 shortcut")
  }
}

@Suite("Agent configuration reload")
struct AgentConfigurationReloadTests {
  @Test("Reload skips unresolved bundle IDs and installs resolvable bindings")
  @MainActor
  func reloadSkipsUnresolvedBundleIDs() async throws {
    let configuration = KeybinddConfigurationV1(
      bindings: [
        try storedBinding(key: "f5", mods: ["cmd"], bundleID: "com.apple.safari"),
        try storedBinding(key: "f6", mods: ["cmd"], bundleID: "com.example.missing"),
      ]
    )
    let store = InMemoryConfigurationStore()
    try store.save(configuration)
    let resolver = TestAppResolver(appsByBundleID: [
      "com.apple.safari": makeIdentity(bundleID: "com.apple.safari")
    ])
    let reloader = AgentConfigurationReloader(store: store, appResolver: resolver)

    let reload = reloader.reload()
    let snapshot = try #require(reload.snapshotToInstall)

    #expect(reload.configState == .ok)
    #expect(reload.bindingCount == 1)
    #expect(reload.lastReloadError == nil)
    #expect(reload.unresolvedBundleIDs == ["com.example.missing"])

    let fields = reloader.statusFields()
    #expect(fields.configState == .ok)
    #expect(fields.bindingCount == 1)
    #expect(fields.lastReloadError == nil)
    #expect(fields.unresolvedBundleIDs == ["com.example.missing"])

    let installedShortcut = try BindingCompiler.compileShortcut(
      Shortcut(key: "f5", mods: ["cmd"])
    )
    #expect(
      snapshot.binding(for: installedShortcut)?.identity.bundleIdentifier == "com.apple.safari")
  }

  @Test("Hard invalid reload preserves the previous engine snapshot")
  @MainActor
  func hardInvalidReloadPreservesPreviousSnapshot() async throws {
    let initialConfiguration = KeybinddConfigurationV1(
      bindings: [
        try storedBinding(key: "f5", mods: ["cmd"], bundleID: "com.apple.safari")
      ]
    )
    let store = MutableLoadedConfigurationStore(configuration: initialConfiguration)
    let resolver = TestAppResolver(appsByBundleID: [
      "com.apple.safari": makeIdentity(bundleID: "com.apple.safari")
    ])
    let reloader = AgentConfigurationReloader(store: store, appResolver: resolver)

    let firstReload = reloader.reload()
    let firstSnapshot = try #require(firstReload.snapshotToInstall)

    store.configuration =
      KeybinddConfigurationV1(
        bindings: [
          StoredBinding(
            shortcut: Shortcut(key: "not-a-key", mods: ["cmd"]),
            target: try AppTarget(bundleID: "com.apple.safari", mode: .launch)
          )
        ]
      )
    let failedReload = reloader.reload()

    #expect(failedReload.configState == .invalid)
    #expect(failedReload.snapshotToInstall == nil)
    #expect(failedReload.bindingCount == 1)
    #expect(failedReload.unresolvedBundleIDs.isEmpty)

    let preservedShortcut = try BindingCompiler.compileShortcut(
      Shortcut(key: "f5", mods: ["cmd"])
    )
    #expect(
      firstSnapshot.binding(for: preservedShortcut)?.identity.bundleIdentifier == "com.apple.safari"
    )
  }
}

@Suite("XPC client code-signing requirement")
struct XPCClientRequirementTests {
  @Test("Pins clients by exact bundle id, never a quoted wildcard")
  func buildsClientAllowList() {
    let requirement = XPCClientRequirement.clientRequirementString(teamIdentifier: "TEAMID1234")
    #expect(
      requirement == """
        anchor apple generic and certificate leaf[subject.OU] = "TEAMID1234" and (info[CFBundleIdentifier] = "net.garaba.keybindd" or info[CFBundleIdentifier] = "net.garaba.keybindd.ui")
        """
    )
    // Regression guard: a quoted "...*" is a literal asterisk in the requirement
    // language and never matches, which silently rejects every client.
    #expect(!requirement.contains("*\""))
  }

  @Test("Escapes requirement string values")
  func escapesValues() {
    let requirement = XPCClientRequirement.clientRequirementString(
      teamIdentifier: #"TEAM"ID"#,
      bundleIdentifiers: [#"net.garaba\keybindd"#]
    )
    #expect(
      requirement == #"""
        anchor apple generic and certificate leaf[subject.OU] = "TEAM\"ID" and (info[CFBundleIdentifier] = "net.garaba\\keybindd")
        """#
    )
  }

  @Test("Generated client requirement string compiles")
  func generatedRequirementStringCompiles() {
    let requirementString =
      XPCClientRequirement.clientRequirementString(teamIdentifier: "ABCDE12345")

    var requirement: SecRequirement?
    let status = SecRequirementCreateWithString(
      requirementString as CFString,
      SecCSFlags(),
      &requirement
    )

    #expect(status == errSecSuccess)
  }

  @Test("Builds an exact same-team requirement for the agent bundle identifier")
  func buildsExactAgentRequirement() {
    #expect(
      XPCClientRequirement.requirementString(
        teamIdentifier: "TEAMID1234",
        bundleIdentifier: KeybinddBundleIdentifiers.agent
      )
        == """
        anchor apple generic and certificate leaf[subject.OU] = "TEAMID1234" and info[CFBundleIdentifier] = "net.garaba.keybindd.agent"
        """
    )
  }

  @Test("Generated exact requirement string compiles")
  func generatedExactRequirementStringCompiles() {
    let requirementString =
      XPCClientRequirement.requirementString(
        teamIdentifier: "ABCDE12345",
        bundleIdentifier: KeybinddBundleIdentifiers.agent
      )

    var requirement: SecRequirement?
    let status = SecRequirementCreateWithString(
      requirementString as CFString,
      SecCSFlags(),
      &requirement
    )

    #expect(status == errSecSuccess)
  }
}

@Suite("XPC async bridge")
struct XPCAsyncBridgeTests {
  @Test("Returns a single reply")
  func returnsSingleReply() async throws {
    let value: Int = try await XPCAsyncBridge.perform(operation: "reply") { responder in
      responder.resume(returning: 42)
    }

    #expect(value == 42)
  }

  @Test("Surfaces a single error")
  func surfacesSingleError() async {
    do {
      let _: Int = try await XPCAsyncBridge.perform(operation: "error") { responder in
        responder.resume(throwing: TestXPCBridgeError.expected)
      }
      Issue.record("Expected XPC bridge error")
    } catch let error as TestXPCBridgeError {
      #expect(error == .expected)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test("Ignores callbacks after the first resume")
  func ignoresCallbacksAfterFirstResume() async throws {
    let value: Int = try await XPCAsyncBridge.perform(operation: "double") { responder in
      responder.resume(returning: 7)
      responder.resume(throwing: TestXPCBridgeError.unexpected)
      responder.resume(returning: 9)
    }

    #expect(value == 7)
  }

  @Test("Times out when no callback arrives")
  func timesOutWhenNoCallbackArrives() async {
    do {
      let _: Int = try await XPCAsyncBridge.perform(
        operation: "never",
        timeoutNanoseconds: 20_000_000
      ) { _ in }
      Issue.record("Expected XPC timeout")
    } catch let error as XPCBridgeError {
      #expect(error == .timedOut(operation: "never"))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }
}

private enum TestXPCBridgeError: Error, Equatable {
  case expected
  case unexpected
}

private final class MutableLoadedConfigurationStore: @unchecked Sendable, ConfigurationStore {
  private let lock = NSLock()
  private var storedConfiguration: KeybinddConfigurationV1

  var configuration: KeybinddConfigurationV1 {
    get {
      lock.withLock { storedConfiguration }
    }
    set {
      lock.withLock {
        storedConfiguration = newValue
      }
    }
  }

  init(configuration: KeybinddConfigurationV1) {
    self.storedConfiguration = configuration
  }

  func load() -> ConfigurationLoadResult {
    .loaded(configuration)
  }

  func save(_ configuration: KeybinddConfigurationV1) throws {
    try validateConfiguration(configuration)
    self.configuration = configuration
  }
}

private func storedBinding(
  key: String,
  mods: [String],
  bundleID: String
) throws -> StoredBinding {
  StoredBinding(
    shortcut: Shortcut(key: key, mods: mods),
    target: try AppTarget(bundleID: bundleID, mode: .launch)
  )
}
