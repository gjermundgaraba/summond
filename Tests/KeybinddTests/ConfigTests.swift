import Foundation
import Testing

@testable import keybindd

@Suite("Binding config loading")
struct ConfigTests {
  @Test("Loads a valid TOML config into bindings and snapshot")
  func validConfig() throws {
    let toml = """
      [[bindings]]
      key = "f5"
      mods = ["cmd", "shift"]
      app = { bundle_id = "com.apple.Safari", mode = "current_space" }

      [[bindings]]
      key = "space"
      mods = ["cmd"]
      app = { bundle_id = "com.apple.Terminal", mode = "launch" }
      """

    let result = try loadConfig(
      toml,
      resolver: TestAppResolver(
        appsByBundleID: [
          "com.apple.Safari": makeIdentity(bundleID: "com.apple.Safari"),
          "com.apple.Terminal": makeIdentity(bundleID: "com.apple.Terminal"),
        ]
      )
    )

    #expect(result.bindings.count == 2)
    #expect(result.snapshot.count == 2)
    #expect(result.bindings[0].description == "cmd+shift+f5")
    #expect(result.bindings[0].app.bundleID == "com.apple.Safari")
    #expect(result.bindings[0].app.mode == .currentSpace)
    #expect(result.bindings[1].app.mode == .launch)
  }

  @Test("Loads a valid TOML config written with nested app tables")
  func validConfigWithNestedAppTable() throws {
    let toml = """
      [[bindings]]
      key = "f5"
      mods = ["cmd"]

      [bindings.app]
      bundle_id = "com.apple.Safari"
      mode = "current_space"
      """

    let result = try loadConfig(
      toml,
      resolver: TestAppResolver(
        appsByBundleID: [
          "com.apple.Safari": makeIdentity(bundleID: "com.apple.Safari")
        ]
      )
    )

    #expect(result.bindings.count == 1)
    #expect(result.bindings[0].description == "cmd+f5")
    #expect(result.bindings[0].app.bundleID == "com.apple.Safari")
    #expect(result.bindings[0].app.mode == .currentSpace)
  }

  @Test("Invalid bindings fail the entire file")
  func invalidBindings() throws {
    for testCase in invalidBindingCases {
      try assertInvalidBinding(
        toml: testCase.toml,
        error: testCase.error
      )
    }
  }

  @Test("Duplicate compiled shortcuts fail the entire file")
  func duplicateShortcut() throws {
    let toml = """
      [[bindings]]
      key = "return"
      mods = ["cmd"]
      app = { bundle_id = "com.apple.Safari", mode = "launch" }

      [[bindings]]
      key = "enter"
      mods = ["cmd"]
      app = { bundle_id = "com.apple.Terminal", mode = "current_space" }
      """

    #expect(throws: BindingConfigError.duplicateShortcut(index: 2, description: "cmd+enter")) {
      try loadConfig(
        toml,
        resolver: TestAppResolver(
          appsByBundleID: [
            "com.apple.Safari": makeIdentity(bundleID: "com.apple.Safari"),
            "com.apple.Terminal": makeIdentity(bundleID: "com.apple.Terminal"),
          ]
        )
      )
    }
  }

  @Test("Unresolved bundle ID fails the entire file")
  func unresolvedBundleID() throws {
    let toml = """
      [[bindings]]
      key = "f5"
      mods = ["cmd"]
      app = { bundle_id = "com.example.missing", mode = "launch" }
      """

    #expect(
      throws: BindingConfigError.unresolvedBundleID(index: 1, bundleID: "com.example.missing")
    ) {
      try loadConfig(toml, resolver: TestAppResolver(appsByBundleID: [:]))
    }
  }

  @Test("Empty bindings array is valid")
  func emptyBindings() throws {
    let toml = """
      bindings = []
      """

    let result = try loadConfig(toml, resolver: TestAppResolver(appsByBundleID: [:]))
    #expect(result.bindings.isEmpty)
    #expect(result.snapshot.count == 0)
  }

  @Test("Throws on malformed TOML")
  func malformedToml() {
    let toml = """
      [[bindings]]
      key = "f5"
      mods = INVALID
      """

    #expect(throws: BindingConfigError.self) {
      try loadConfig(toml)
    }
  }

  @Test("Comments-only file is rejected")
  func commentsOnlyFile() {
    let toml = """
      # This is a comment
      # Another comment

      """

    #expect(throws: BindingConfigError.self) {
      try loadConfig(toml, resolver: TestAppResolver(appsByBundleID: [:]))
    }
  }

  @Test("Non-UTF8 data throws instead of being treated as empty")
  func nonUTF8DataThrows() {
    #expect(throws: BindingConfigError.self) {
      try withConfigFile(Data([0xFF])) { path in
        try BindingConfigStore.load(from: path, appResolver: TestAppResolver(appsByBundleID: [:]))
      }
    }
  }

  @Test("Normalization lowercases key modifiers and preserves bundle ID casing")
  func normalization() throws {
    let toml = """
      [[bindings]]
      key = "F5"
      mods = ["CMD", "Shift"]
      app = { bundle_id = "Com.Apple.Safari", mode = "launch" }
      """

    let result = try loadConfig(
      toml,
      resolver: TestAppResolver(
        appsByBundleID: ["Com.Apple.Safari": makeIdentity(bundleID: "com.apple.Safari")]
      )
    )
    #expect(result.bindings[0].shortcut.key == "f5")
    #expect(result.bindings[0].shortcut.mods == ["cmd", "shift"])
    #expect(result.bindings[0].app.bundleID == "Com.Apple.Safari")
  }
}

@Suite("Binding compiler")
struct BindingCompilerTests {
  @Test("Compiling a single binding fails when the bundle is missing")
  func unresolvedBundleID() throws {
    let binding = try makeBinding(bundleID: "com.example.missing")

    #expect(throws: BindingCompilationError.unresolvedBundleID("com.example.missing")) {
      try BindingCompiler.compileBinding(
        binding,
        appResolver: TestAppResolver(appsByBundleID: [:])
      )
    }
  }
}

@Suite("Config serialization")
struct ConfigSerializationTests {
  @Test("Serializes bindings into a parseable config")
  func serializeRoundTrip() throws {
    let bindings = [
      try makeBinding(key: "f5", mods: ["cmd"], bundleID: "com.apple.safari", mode: .launch),
      try makeBinding(
        key: "space", mods: ["cmd", "shift"], bundleID: "com.apple.terminal", mode: .currentSpace),
    ]

    let result = BindingConfigDocument.serialize(bindings)
    let parsed = try BindingConfigDocument.parse(Data(result.utf8))

    #expect(parsed == bindings)
  }

  @Test("Serializes empty bindings as an explicit empty bindings document")
  func serializeEmpty() {
    let result = BindingConfigDocument.serialize([])
    #expect(result == "bindings = []\n")
  }

  @Test("Config auto-create and load")
  func ensureConfigAndLoadEntries() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let configPath = tmpDir.appendingPathComponent("test-keybindd.toml").path

    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let created = BindingConfigStore.ensureExists(at: configPath)
    #expect(created == true)
    #expect(FileManager.default.fileExists(atPath: configPath))
    let content = try String(contentsOfFile: configPath, encoding: .utf8)
    #expect(content == "bindings = []\n")

    let again = BindingConfigStore.ensureExists(at: configPath)
    #expect(again == false)

    let result = try BindingConfigStore.load(
      from: configPath, appResolver: TestAppResolver(appsByBundleID: [:]))
    #expect(result.bindings.isEmpty)
    #expect(result.snapshot.count == 0)
  }

  @Test("Config auto-create supports relative paths")
  func ensureConfigWithRelativePaths() throws {
    for configPath in ["keybindd.toml", "configs/keybindd.toml"] {
      try assertEnsureExistsSupportsRelativePath(configPath)
    }
  }
}

private let invalidBindingCases: [(toml: String, error: BindingValidationError)] = [
  (
    toml: """
    [[bindings]]
    key = "nonexistent"
    mods = ["cmd"]
    app = { bundle_id = "com.apple.Safari", mode = "launch" }
    """,
    error: .unknownKey("nonexistent")
  ),
  (
    toml: """
    [[bindings]]
    key = "a"
    mods = ["cmd", "super"]
    app = { bundle_id = "com.apple.Safari", mode = "launch" }
    """,
    error: .unknownModifiers(["super"])
  ),
  (
    toml: """
    [[bindings]]
    key = "a"
    mods = ["cmd"]
    app = { bundle_id = "com.apple.Safari", mode = "focus" }
    """,
    error: .unknownMode("focus")
  ),
  (
    toml: """
    [[bindings]]
    key = "a"
    mods = ["cmd"]
    app = { bundle_id = "", mode = "launch" }
    """,
    error: .emptyBundleID
  ),
]

private func assertInvalidBinding(
  toml: String,
  error: BindingValidationError,
  resolver: TestAppResolver = TestAppResolver(
    appsByBundleID: ["com.apple.safari": makeIdentity(bundleID: "com.apple.safari")]
  )
) throws {
  #expect(throws: BindingConfigError.invalidBinding(index: 1, error: error)) {
    try loadConfig(toml, resolver: resolver)
  }
}

private func assertEnsureExistsSupportsRelativePath(_ configPath: String) throws {
  try withTemporaryCurrentDirectory { tempDirectory in
    let created = BindingConfigStore.ensureExists(at: configPath)
    #expect(created == true)
    #expect(
      FileManager.default.fileExists(atPath: tempDirectory.appendingPathComponent(configPath).path))
  }
}

private func loadConfig(
  _ toml: String,
  resolver: TestAppResolver = TestAppResolver(
    appsByBundleID: ["com.apple.safari": makeIdentity(bundleID: "com.apple.safari")]
  )
) throws -> BindingConfigLoadResult {
  try withConfigFile(Data(toml.utf8)) { path in
    try BindingConfigStore.load(from: path, appResolver: resolver)
  }
}

private func withConfigFile<T>(_ data: Data, _ body: (String) throws -> T) throws -> T {
  let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: tmpDir) }

  let configURL = tmpDir.appendingPathComponent("keybindd.toml")
  try data.write(to: configURL)
  return try body(configURL.path)
}
