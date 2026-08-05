import CoreGraphics
import Foundation
import MachO
import Security
import Testing

@testable import SummondCore

@Suite("Mach-O symbol validation")
struct MachOSymbolValidationTests {
  @Test("Accepts only defined section symbols with addresses")
  func callableSymbols() {
    #expect(
      SpaceMover.isCallableSymbol(
        type: UInt8(N_SECT), section: 1, value: 0x1000
      ))
    #expect(!SpaceMover.isCallableSymbol(type: UInt8(N_UNDF), section: 0, value: 0))
    #expect(!SpaceMover.isCallableSymbol(type: UInt8(N_SECT), section: 1, value: 0))
    #expect(
      !SpaceMover.isCallableSymbol(
        type: UInt8(N_STAB) | UInt8(N_SECT), section: 1, value: 0x1000
      ))
  }
}

@Suite("Agent status")
struct AgentStatusTests {
  @Test("JSON round trip preserves agent status")
  func jsonRoundTrip() throws {
    let status = AgentStatus(
      agentVersion: "1.2.3",
      accessibilityGranted: true,
      shortcutsActive: false,
      failedShortcuts: ["cmd+f5"],
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
    let incompleteJSON = """
      {"agentVersion":"1.0.0","accessibilityGranted":true,"shortcutsActive":true,\
      "configState":"ok","bindingCount":3}
      """

    #expect(throws: DecodingError.self) {
      try AgentStatusCodec.decode(Data(incompleteJSON.utf8))
    }
  }
}

@Suite("System health")
struct SystemHealthTests {
  @Test("Evaluates every agent health outcome in precedence order")
  func evaluatesAgentOutcomes() {
    let cases: [(AgentStatus?, SystemHealth)] = [
      (nil, .degraded(.agentUnavailable)),
      (
        status(accessibilityGranted: false),
        .setupRequired(.accessibilityPermission)
      ),
      (
        status(configState: .unavailable, lastReloadError: "permission denied"),
        .degraded(.configurationUnavailable(details: "permission denied"))
      ),
      (
        status(configState: .corrupt, lastReloadError: "decode failed"),
        .degraded(.configurationCorrupt(details: "decode failed"))
      ),
      (
        status(configState: .invalid, lastReloadError: "duplicate shortcut"),
        .degraded(.configurationInvalid(details: "duplicate shortcut"))
      ),
      (
        status(unresolvedBundleIDs: ["com.example.one", "com.example.two"]),
        .degraded(
          .unresolvedApplications(bundleIDs: ["com.example.one", "com.example.two"])
        )
      ),
      (status(shortcutsActive: false), .degraded(.shortcutListenerInactive)),
      (
        status(failedShortcuts: ["cmd+f5"]),
        .degraded(.shortcutRegistrationFailures(shortcuts: ["cmd+f5"]))
      ),
      (status(configState: .fresh, bindingCount: 0), .ready(activeShortcuts: 0)),
      (status(bindingCount: 5), .ready(activeShortcuts: 5)),
    ]

    for (status, expected) in cases {
      #expect(SystemHealth.evaluate(agentStatus: status) == expected)
    }
  }

  @Test("Evaluates every service registration outcome before agent state")
  func evaluatesServiceOutcomesFirst() {
    let unhealthyAgent = status(
      accessibilityGranted: false,
      shortcutsActive: false,
      failedShortcuts: ["cmd+f5"],
      configState: .invalid,
      lastReloadError: "invalid",
      unresolvedBundleIDs: ["com.example.missing"]
    )
    let cases: [(ServiceRegistrationStatus, SystemHealth)] = [
      (.requiresApproval, .setupRequired(.backgroundServiceApprovalRequired)),
      (.notRegistered, .setupRequired(.backgroundServiceNotRegistered)),
      (.notFound, .setupRequired(.backgroundServiceNotFound)),
      (.enabled, .setupRequired(.accessibilityPermission)),
    ]

    for (serviceStatus, expected) in cases {
      #expect(
        SystemHealth.evaluate(serviceStatus: serviceStatus, agentStatus: unhealthyAgent) == expected
      )
    }
  }

  private func status(
    accessibilityGranted: Bool = true,
    shortcutsActive: Bool = true,
    failedShortcuts: [String] = [],
    configState: AgentConfigurationState = .ok,
    bindingCount: Int = 3,
    lastReloadError: String? = nil,
    unresolvedBundleIDs: [String] = []
  ) -> AgentStatus {
    AgentStatus(
      agentVersion: "test",
      accessibilityGranted: accessibilityGranted,
      shortcutsActive: shortcutsActive,
      failedShortcuts: failedShortcuts,
      configState: configState,
      bindingCount: bindingCount,
      lastReloadError: lastReloadError,
      unresolvedBundleIDs: unresolvedBundleIDs
    )
  }
}

@Suite("Agent configuration reload")
struct AgentConfigurationReloadTests {
  @Test("Reload skips unresolved bundle IDs and installs resolvable bindings")
  @MainActor
  func reloadSkipsUnresolvedBundleIDs() async throws {
    let configuration = SummondConfiguration(
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

    #expect(reload.lastReloadError == nil)

    let fields = reloader.statusFields()
    #expect(fields.configState == .ok)
    #expect(fields.bindingCount == 1)
    #expect(fields.lastReloadError == nil)
    #expect(fields.unresolvedBundleIDs == ["com.example.missing"])

    let installedShortcut = try BindingCompiler.compileShortcut(
      Shortcut(key: "f5", mods: ["cmd"])
    )
    #expect(
      snapshot.bindingsByTrigger[installedShortcut]?.identity.bundleIdentifier
        == "com.apple.safari")
  }

  @Test("Hard invalid reload preserves the previous engine snapshot")
  @MainActor
  func hardInvalidReloadPreservesPreviousSnapshot() async throws {
    let initialConfiguration = SummondConfiguration(
      bindings: [
        try storedBinding(key: "f5", mods: ["cmd"], bundleID: "com.apple.safari")
      ],
      verboseLogging: true
    )
    let store = MutableLoadedConfigurationStore(configuration: initialConfiguration)
    let resolver = TestAppResolver(appsByBundleID: [
      "com.apple.safari": makeIdentity(bundleID: "com.apple.safari")
    ])
    let reloader = AgentConfigurationReloader(store: store, appResolver: resolver)

    let firstReload = reloader.reload()
    let firstSnapshot = try #require(firstReload.snapshotToInstall)
    #expect(firstReload.verboseLogging)

    store.configuration =
      SummondConfiguration(
        bindings: [
          StoredBinding(
            shortcut: Shortcut(key: "not-a-key", mods: ["cmd"]),
            target: try AppTarget(bundleID: "com.apple.safari", mode: .launch)
          )
        ]
      )
    let failedReload = reloader.reload()

    #expect(failedReload.snapshotToInstall == nil)
    #expect(failedReload.verboseLogging)

    let fields = reloader.statusFields()
    #expect(fields.configState == .invalid)
    #expect(fields.bindingCount == 1)
    #expect(fields.unresolvedBundleIDs.isEmpty)

    let preservedShortcut = try BindingCompiler.compileShortcut(
      Shortcut(key: "f5", mods: ["cmd"])
    )
    #expect(
      firstSnapshot.bindingsByTrigger[preservedShortcut]?.identity.bundleIdentifier
        == "com.apple.safari"
    )
  }

  @Test("Unavailable storage preserves the previous engine snapshot")
  func unavailableStoragePreservesPreviousSnapshot() throws {
    let initialConfiguration = SummondConfiguration(
      bindings: [
        try storedBinding(key: "f5", mods: ["cmd"], bundleID: "com.apple.safari")
      ],
      verboseLogging: true
    )
    let store = MutableLoadedConfigurationStore(configuration: initialConfiguration)
    let reloader = AgentConfigurationReloader(
      store: store,
      appResolver: TestAppResolver(appsByBundleID: [
        "com.apple.safari": makeIdentity(bundleID: "com.apple.safari")
      ])
    )

    #expect(reloader.reload().snapshotToInstall != nil)
    store.loadError = CocoaError(.fileReadNoPermission)

    let failedReload = reloader.reload()
    let fields = reloader.statusFields()

    #expect(failedReload.snapshotToInstall == nil)
    #expect(failedReload.verboseLogging)
    #expect(fields.configState == .unavailable)
    #expect(fields.bindingCount == 1)
    #expect(fields.lastReloadError != nil)
  }
}

@Suite("XPC client code-signing requirement")
struct XPCClientRequirementTests {
  @Test("Pins clients by exact bundle id, never a quoted wildcard")
  func buildsClientAllowList() {
    let requirement = XPCClientRequirement.clientRequirementString(teamIdentifier: "TEAMID1234")
    #expect(
      requirement == """
        anchor apple generic and certificate leaf[subject.OU] = "TEAMID1234" and (info[CFBundleIdentifier] = "net.garaba.summond" or info[CFBundleIdentifier] = "net.garaba.summond.ui")
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
      bundleIdentifiers: [#"net.garaba\summond"#]
    )
    #expect(
      requirement == #"""
        anchor apple generic and certificate leaf[subject.OU] = "TEAM\"ID" and (info[CFBundleIdentifier] = "net.garaba\\summond")
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
        bundleIdentifier: SummondBundleIdentifiers.agent
      )
        == """
        anchor apple generic and certificate leaf[subject.OU] = "TEAMID1234" and info[CFBundleIdentifier] = "net.garaba.summond.agent"
        """
    )
  }

  @Test("Generated exact requirement string compiles")
  func generatedExactRequirementStringCompiles() {
    let requirementString =
      XPCClientRequirement.requirementString(
        teamIdentifier: "ABCDE12345",
        bundleIdentifier: SummondBundleIdentifiers.agent
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

@Suite("LaunchAgent property list")
struct LaunchAgentPlistTests {
  @Test("Ships a LaunchAgent plist whose wiring matches the client and bundle layout")
  func plistMatchesContract() throws {
    let data = try Data(contentsOf: agentPlistURL())
    let rawPlist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    let plist = try #require(rawPlist as? [String: Any])
    let machServices = try #require(plist["MachServices"] as? [String: Bool])
    let keepAlive = try #require(plist["KeepAlive"] as? [String: Bool])

    #expect(plist["Label"] as? String == SummondBundleIdentifiers.agent)
    #expect(machServices == [SummondBundleIdentifiers.agentMachService: true])
    #expect(
      plist["BundleProgram"] as? String
        == "Contents/MacOS/SummondAgent.app/Contents/MacOS/SummondAgent")
    #expect(plist["AssociatedBundleIdentifiers"] as? String == SummondBundleIdentifiers.app)
    #expect(plist["RunAtLoad"] as? Bool == true)
    #expect(plist["LimitLoadToSessionType"] as? String == "Aqua")
    #expect(keepAlive["SuccessfulExit"] == false)
  }

  /// The source plist, located relative to this test file so it is independent
  /// of the test runner's working directory. From
  /// `<repo>/Core/Tests/SummondTests/AgentSupportTests.swift` the repo root is
  /// four parents up.
  private func agentPlistURL(_ file: String = #filePath) -> URL {
    URL(fileURLWithPath: file)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("App/Resources/net.garaba.summond.agent.plist")
  }
}

private enum TestXPCBridgeError: Error, Equatable {
  case expected
  case unexpected
}

private final class MutableLoadedConfigurationStore: @unchecked Sendable, ConfigurationStore {
  private let lock = NSLock()
  private var storedConfiguration: SummondConfiguration
  private var storedLoadError: Error?

  var configuration: SummondConfiguration {
    get {
      lock.withLock { storedConfiguration }
    }
    set {
      lock.withLock {
        storedConfiguration = newValue
      }
    }
  }

  var loadError: Error? {
    get { lock.withLock { storedLoadError } }
    set { lock.withLock { storedLoadError = newValue } }
  }

  init(configuration: SummondConfiguration) {
    self.storedConfiguration = configuration
  }

  func load() throws -> SummondConfiguration? {
    if let loadError { throw loadError }
    return configuration
  }

  func save(_ configuration: SummondConfiguration) throws {
    try ConfigurationValidator.validate(configuration)
    self.configuration = configuration
  }

  func replace(with configuration: SummondConfiguration) {
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
