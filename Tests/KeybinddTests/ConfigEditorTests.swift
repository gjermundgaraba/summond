import Foundation
import Testing

@testable import keybindd

@Suite("Config editing")
struct ConfigEditorTests {
  @Test("Add rejects malformed existing config and leaves file untouched")
  func addRejectsMalformedConfig() throws {
    let malformed = """
      [[bindings]]
      key = "f5"
      mods = INVALID
      """

    try withWrittenConfig(malformed) { configURL in
      #expect(throws: BindingEditError.self) {
        try BindingConfigStore.add(
          try makeBinding(key: "f6", mods: ["cmd"], bundleID: "com.apple.safari", mode: .launch),
          to: configURL.path,
          resolver: TestAppResolver(appsByBundleID: [
            "com.apple.safari": makeIdentity(bundleID: "com.apple.safari")
          ])
        )
      }

      let content = try String(contentsOf: configURL, encoding: .utf8)
      #expect(content == malformed)
    }
  }

  @Test("Add wraps config read failures as file access errors")
  func addWrapsReadFailures() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    do {
      _ = try BindingConfigStore.add(
        try makeBinding(key: "f6", mods: ["cmd"], bundleID: "com.apple.safari", mode: .launch),
        to: tmpDir.path,
        resolver: TestAppResolver(appsByBundleID: [
          "com.apple.safari": makeIdentity(bundleID: "com.apple.safari")
        ])
      )
      Issue.record("Expected config read failure")
    } catch let error as BindingEditError {
      guard case .fileAccess(let message) = error else {
        Issue.record("Expected fileAccess error, got \(error)")
        return
      }
      #expect(message.contains("Failed to read config"))
    }
  }

  @Test("Add reports config creation failures as file access errors")
  func addWrapsCreateFailures() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tmpDir.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpDir.path)
      try? FileManager.default.removeItem(at: tmpDir)
    }

    do {
      _ = try BindingConfigStore.add(
        try makeBinding(key: "f6", mods: ["cmd"], bundleID: "com.apple.safari", mode: .launch),
        to: tmpDir.appendingPathComponent("keybindd.toml").path,
        resolver: TestAppResolver(appsByBundleID: [
          "com.apple.safari": makeIdentity(bundleID: "com.apple.safari")
        ])
      )
      Issue.record("Expected config create failure")
    } catch let error as BindingEditError {
      guard case .fileAccess(let message) = error else {
        Issue.record("Expected fileAccess error, got \(error)")
        return
      }
      #expect(message.contains("Failed to create config"))
    }
  }

  @Test("Add rejects semantically invalid existing config and leaves file untouched")
  func addRejectsInvalidExistingBinding() throws {
    let invalid = """
      [[bindings]]
      key = "not-a-key"
      mods = ["cmd"]
      app = { bundle_id = "com.apple.safari", mode = "launch" }
      """

    try withWrittenConfig(invalid) { configURL in
      #expect(
        throws: BindingEditError.invalidConfig(
          .invalidBinding(index: 1, error: .unknownKey("not-a-key")))
      ) {
        try BindingConfigStore.add(
          try makeBinding(key: "f6", mods: ["cmd"], bundleID: "com.apple.safari", mode: .launch),
          to: configURL.path,
          resolver: TestAppResolver(appsByBundleID: [
            "com.apple.safari": makeIdentity(bundleID: "com.apple.safari")
          ])
        )
      }

      let content = try String(contentsOf: configURL, encoding: .utf8)
      #expect(content == invalid)
    }
  }

  @Test("Add rejects unresolved bundle IDs")
  func addRejectsUnresolvedBundleID() throws {
    #expect(throws: BindingEditError.unresolvedBundleID("com.example.missing")) {
      try BindingConfigStore.add(
        try makeBinding(key: "f6", mods: ["cmd"], bundleID: "com.example.missing", mode: .launch),
        to: "/tmp/keybindd.toml",
        resolver: TestAppResolver(appsByBundleID: [:])
      )
    }
  }

  @Test("Add rejects duplicate compiled shortcuts")
  func addRejectsDuplicateShortcut() throws {
    let existing = """
      [[bindings]]
      key = "return"
      mods = ["cmd"]
      app = { bundle_id = "com.apple.safari", mode = "launch" }
      """

    try withWrittenConfig(existing) { configURL in
      #expect(throws: BindingEditError.duplicateBinding("cmd+return")) {
        try BindingConfigStore.add(
          try makeBinding(
            key: "enter", mods: ["cmd"], bundleID: "com.apple.terminal", mode: .launch),
          to: configURL.path,
          resolver: TestAppResolver(
            appsByBundleID: [
              "com.apple.safari": makeIdentity(bundleID: "com.apple.safari"),
              "com.apple.terminal": makeIdentity(bundleID: "com.apple.terminal"),
            ]
          )
        )
      }
    }
  }

  @Test("Add serializes current_space mode")
  func addSerializesCurrentSpaceMode() throws {
    try withTemporaryConfigURL { configURL in
      let result = try BindingConfigStore.add(
        try makeBinding(
          key: "f6", mods: ["cmd"], bundleID: "com.apple.safari", mode: .currentSpace),
        to: configURL.path,
        resolver: TestAppResolver(appsByBundleID: [
          "com.apple.safari": makeIdentity(bundleID: "com.apple.safari")
        ])
      )

      let content = try String(contentsOf: configURL, encoding: .utf8)
      #expect(result.app.mode == .currentSpace)
      #expect(content.contains("mode = \"current_space\""))
    }
  }

  @Test("Remove rejects semantically invalid existing config and leaves file untouched")
  func removeRejectsInvalidExistingBinding() throws {
    let invalid = """
      [[bindings]]
      key = "f5"
      mods = ["super"]
      app = { bundle_id = "com.apple.safari", mode = "launch" }
      """

    try withWrittenConfig(invalid) { configURL in
      let selector = BindingSelector.shortcut(
        try BindingCompiler.compileShortcut(Shortcut(key: "f5", mods: ["cmd"])),
        description: "cmd+f5"
      )
      #expect(
        throws: BindingEditError.invalidConfig(
          .invalidBinding(index: 1, error: .unknownModifiers(["super"])))
      ) {
        try BindingConfigStore.remove(
          selector,
          from: configURL.path,
          appResolver: TestAppResolver(appsByBundleID: [
            "com.apple.safari": makeIdentity(bundleID: "com.apple.safari")
          ])
        )
      }

      let content = try String(contentsOf: configURL, encoding: .utf8)
      #expect(content == invalid)
    }
  }

  @Test("Remove wraps config read failures as file access errors")
  func removeWrapsReadFailures() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let selector = BindingSelector.shortcut(
      try BindingCompiler.compileShortcut(Shortcut(key: "f5", mods: ["cmd"])),
      description: "cmd+f5"
    )

    do {
      _ = try BindingConfigStore.remove(
        selector,
        from: tmpDir.path,
        appResolver: TestAppResolver(appsByBundleID: [
          "com.apple.safari": makeIdentity(bundleID: "com.apple.safari")
        ])
      )
      Issue.record("Expected config read failure")
    } catch let error as BindingEditError {
      guard case .fileAccess(let message) = error else {
        Issue.record("Expected fileAccess error, got \(error)")
        return
      }
      #expect(message.contains("Failed to read config"))
    }
  }

  @Test("Remove by bare key is rejected when multiple bindings match")
  func removeRejectsAmbiguousBareKeyMatch() throws {
    let config = """
      [[bindings]]
      key = "f5"
      mods = ["cmd"]
      app = { bundle_id = "com.apple.safari", mode = "launch" }

      [[bindings]]
      key = "f5"
      mods = ["shift"]
      app = { bundle_id = "com.apple.terminal", mode = "launch" }
      """

    try withWrittenConfig(config) { configURL in
      let selector = BindingSelector.key(
        keyCode: try BindingCompiler.compileShortcut(Shortcut(key: "f5", mods: [])).keyCode,
        description: "f5"
      )
      #expect(throws: BindingEditError.ambiguousMatch("f5")) {
        try BindingConfigStore.remove(
          selector,
          from: configURL.path,
          appResolver: TestAppResolver(
            appsByBundleID: [
              "com.apple.safari": makeIdentity(bundleID: "com.apple.safari"),
              "com.apple.terminal": makeIdentity(bundleID: "com.apple.terminal"),
            ]
          )
        )
      }
    }
  }
}

@Suite("Config add CLI")
struct ConfigAddCLITests {
  @Test("Config add requires exactly one app selector")
  func requiresExactlyOneAppSelector() throws {
    let bundleIDCommand = try KeybinddCLI.Config.Add.parse([
      "--key", "f5",
      "--bundle-id", "com.apple.Safari",
      "--mode", "launch",
    ])
    #expect(bundleIDCommand.bundleID == "com.apple.Safari")
    #expect(bundleIDCommand.applicationPath == nil)

    let applicationPathCommand = try KeybinddCLI.Config.Add.parse([
      "--key", "f5",
      "--application-path", "/Applications/Safari.app",
      "--mode", "launch",
    ])
    #expect(applicationPathCommand.bundleID == nil)
    #expect(applicationPathCommand.applicationPath == "/Applications/Safari.app")

    do {
      _ = try KeybinddCLI.Config.Add.parse([
        "--key", "f5",
        "--mode", "launch",
      ])
      Issue.record("Expected missing app selector to fail validation")
    } catch {
      #expect(String(describing: error).contains("Pass either --bundle-id or --application-path"))
    }

    do {
      _ = try KeybinddCLI.Config.Add.parse([
        "--key", "f5",
        "--bundle-id", "com.apple.Safari",
        "--application-path", "/Applications/Safari.app",
        "--mode", "launch",
      ])
      Issue.record("Expected duplicate app selectors to fail validation")
    } catch {
      #expect(
        String(describing: error).contains(
          "Pass either --bundle-id or --application-path, not both"
        )
      )
    }
  }

  @Test("Config add resolves bundle IDs from application paths")
  func resolvesBundleIDFromApplicationPath() throws {
    let bundleURL = try makeCLIResolverTestApplicationBundle()
    defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }

    let bundleID = try KeybinddCLI.resolvedBundleID(
      bundleID: nil,
      applicationPath: bundleURL.path
    )

    #expect(bundleID == "com.apple.Safari")
  }
}

private func makeCLIResolverTestApplicationBundle() throws -> URL {
  let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let bundleURL = tmpDir.appendingPathComponent("Safari.app")
  let contentsURL = bundleURL.appendingPathComponent("Contents")
  let infoPlistURL = contentsURL.appendingPathComponent("Info.plist")

  try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

  let infoPlist = ["CFBundleIdentifier": "com.apple.Safari"]
  let plistData = try PropertyListSerialization.data(
    fromPropertyList: infoPlist,
    format: .xml,
    options: 0
  )
  try plistData.write(to: infoPlistURL)

  return bundleURL
}

@discardableResult
private func withWrittenConfig<T>(_ content: String, _ body: (URL) throws -> T) throws -> T {
  try withTemporaryConfigURL { configURL in
    try content.write(to: configURL, atomically: true, encoding: .utf8)
    return try body(configURL)
  }
}

private func withTemporaryConfigURL<T>(_ body: (URL) throws -> T) throws -> T {
  let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: tmpDir) }
  return try body(tmpDir.appendingPathComponent("keybindd.toml"))
}
