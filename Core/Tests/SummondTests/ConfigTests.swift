import CoreGraphics
import Foundation
import Testing

@testable import SummondCore

@Suite("Configuration store")
struct ConfigurationStoreTests {
  @Test("Missing data loads as a fresh empty configuration")
  func absentDataLoadsFresh() {
    #expect(InMemoryConfigurationStore().load() == .fresh(.empty))
  }

  @Test("Shared defaults suite is not any product bundle identifier")
  func sharedDefaultsSuiteDoesNotMatchBundleIdentifiers() {
    let bundleIdentifiers = [
      SummondBundleIdentifiers.app,
      SummondBundleIdentifiers.agent,
      SummondBundleIdentifiers.statusItem,
    ]

    for bundleIdentifier in bundleIdentifiers {
      #expect(UserDefaultsConfigurationStore.defaultSuiteName != bundleIdentifier)
    }
  }

  @Test("User defaults store round trips across instances in the same suite")
  func userDefaultsStoreRoundTripsAcrossInstances() throws {
    let suiteName = "net.garaba.summond.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    let writer = try #require(UserDefaultsConfigurationStore(suiteName: suiteName))
    let reader = try #require(UserDefaultsConfigurationStore(suiteName: suiteName))
    let bindingID = try #require(UUID(uuidString: "A30A2D05-2481-4C28-8F61-30475F64C391"))
    let configuration = SummondConfiguration(
      bindings: [
        try stored(
          id: bindingID,
          key: "f5",
          mods: ["cmd"],
          bundleID: "com.apple.Safari",
          mode: .newWindow
        )
      ],
      verboseLogging: true
    )

    try writer.save(configuration)

    #expect(reader.load() == .loaded(configuration))
  }

  @Test("JSON round trip preserves bindings verbatim")
  func jsonRoundTrip() throws {
    let configuration = SummondConfiguration(
      bindings: [
        StoredBinding(
          shortcut: Shortcut(key: "F5", mods: ["CMD", "Shift"]),
          target: try AppTarget(bundleID: "com.apple.Safari", mode: .newWindow)
        )
      ],
      verboseLogging: true
    )
    let store = InMemoryConfigurationStore()

    try store.save(configuration)

    #expect(store.load() == .loaded(configuration))
  }

  @Test("Garbage data loads as corrupt")
  func garbageDataLoadsCorrupt() {
    let store = InMemoryConfigurationStore(data: Data([0xFF]))

    guard case .corrupt(.undecodable) = store.load() else {
      Issue.record("Expected undecodable corruption")
      return
    }
  }

  @Test("Unrecognized schema is detected before decoding its payload")
  func unrecognizedSchemaVersionLoadsCorrupt() throws {
    let data = Data(#"{ "schemaVersion": 2 }"#.utf8)
    let store = InMemoryConfigurationStore(data: data)

    #expect(store.load() == .corrupt(.unsupportedSchemaVersion(2)))
    #expect(throws: ConfigurationCorruption.unsupportedSchemaVersion(2)) {
      try store.save(.empty)
    }
    #expect(store.load() == .corrupt(.unsupportedSchemaVersion(2)))
  }

  @Test("A stale user-defaults writer cannot overwrite an unsupported schema")
  func staleUserDefaultsWriterCannotOverwriteUnsupportedSchema() throws {
    let suiteName = "net.garaba.summond.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    let store = try #require(UserDefaultsConfigurationStore(suiteName: suiteName))
    let newerConfiguration = Data(#"{ "schemaVersion": 2 }"#.utf8)
    defaults.set(newerConfiguration, forKey: UserDefaultsConfigurationStore.defaultKey)
    defaults.synchronize()

    #expect(throws: ConfigurationCorruption.unsupportedSchemaVersion(2)) {
      try store.save(.empty)
    }
    defaults.synchronize()
    #expect(
      defaults.data(forKey: UserDefaultsConfigurationStore.defaultKey) == newerConfiguration
    )
  }

  @Test("Save rejects invalid configurations")
  func saveRejectsInvalidConfigurations() throws {
    let cases: [(SummondConfiguration, ConfigurationValidationError)] = [
      (
        configuration(
          shortcut: Shortcut(key: "nonexistent", mods: ["cmd"]),
          target: try AppTarget(bundleID: "com.apple.Safari", mode: .launch)
        ),
        .invalidShortcut(index: 1, error: .unknownKey("nonexistent"))
      ),
      (
        configuration(
          shortcut: Shortcut(key: "a", mods: ["cmd", "super"]),
          target: try AppTarget(bundleID: "com.apple.Safari", mode: .launch)
        ),
        .invalidShortcut(index: 1, error: .unknownModifiers(["super"]))
      ),
      (
        configuration(
          shortcut: Shortcut(key: "a", mods: ["cmd"]),
          target: AppTarget(uncheckedBundleID: "", mode: .launch)
        ),
        .invalidTarget(index: 1, error: .emptyBundleID)
      ),
      (
        SummondConfiguration(
          bindings: [
            try stored(key: "return", mods: ["cmd"], bundleID: "com.apple.Safari"),
            try stored(key: "enter", mods: ["cmd"], bundleID: "com.apple.Terminal"),
          ]
        ),
        .duplicateShortcut(index: 2, description: "cmd+enter")
      ),
    ]

    for (configuration, error) in cases {
      #expect(throws: error) {
        try InMemoryConfigurationStore().save(configuration)
      }
    }
  }

  @Test("Modifier-less shortcut validates and round trips through JSON")
  func modifierLessShortcutValidatesAndRoundTrips() throws {
    let configuration = SummondConfiguration(
      bindings: [try stored(key: "f5", mods: [], bundleID: "com.apple.Safari")]
    )
    let store = InMemoryConfigurationStore()

    try store.save(configuration)

    #expect(store.load() == .loaded(configuration))
  }
}

@Suite("Binding compiler")
struct BindingCompilerTests {
  @Test("Compiling reports unresolved bundle IDs without installing them")
  func reportsUnresolvedBundleIDs() throws {
    let compiled = try BindingCompiler.compile(
      [try makeBinding(bundleID: "com.example.missing")],
      appResolver: TestAppResolver(appsByBundleID: [:])
    )

    #expect(compiled.snapshot.count == 0)
    #expect(compiled.unresolvedBundleIDs == ["com.example.missing"])
  }

  @Test("Modifier-less shortcut compiles and matches empty modifier events")
  func modifierLessShortcutCompilesAndMatches() throws {
    let compiled = try BindingCompiler.compile(
      [try makeBinding(key: "f5", mods: [], bundleID: "com.apple.safari")],
      appResolver: TestAppResolver(appsByBundleID: [
        "com.apple.safari": makeIdentity(bundleID: "com.apple.safari")
      ])
    )

    let match = compiled.snapshot.match(keyCode: 0x60, modifiers: CGEventFlags())

    #expect(match?.identity.bundleIdentifier == "com.apple.safari")
    #expect(match?.binding.shortcut.mods == [])
  }

  @Test("Modifier-less and modified shortcuts on the same key are distinct")
  func modifierLessAndModifiedSameKeyAreDistinct() throws {
    let compiled = try BindingCompiler.compile(
      [
        try makeBinding(key: "f5", mods: [], bundleID: "com.apple.safari"),
        try makeBinding(key: "f5", mods: ["cmd"], bundleID: "com.apple.Terminal"),
      ],
      appResolver: TestAppResolver(appsByBundleID: [
        "com.apple.safari": makeIdentity(bundleID: "com.apple.safari"),
        "com.apple.Terminal": makeIdentity(bundleID: "com.apple.Terminal"),
      ])
    )

    #expect(compiled.snapshot.count == 2)
    #expect(
      compiled.snapshot.match(keyCode: 0x60, modifiers: CGEventFlags())?.identity.bundleIdentifier
        == "com.apple.safari"
    )
    #expect(
      compiled.snapshot.match(keyCode: 0x60, modifiers: .maskCommand)?.identity.bundleIdentifier
        == "com.apple.Terminal"
    )
  }

  @Test("Compiling rejects a duplicate shortcut")
  func rejectsDuplicateShortcut() throws {
    #expect(
      throws: ConfigurationValidationError.duplicateShortcut(index: 2, description: "cmd+f5")
    ) {
      try BindingCompiler.compile(
        [
          try makeBinding(key: "f5", mods: ["cmd"], bundleID: "com.apple.safari"),
          try makeBinding(key: "f5", mods: ["cmd"], bundleID: "com.apple.Terminal"),
        ],
        appResolver: TestAppResolver(appsByBundleID: [
          "com.apple.safari": makeIdentity(bundleID: "com.apple.safari"),
          "com.apple.Terminal": makeIdentity(bundleID: "com.apple.Terminal"),
        ])
      )
    }
  }
}

private func configuration(
  shortcut: Shortcut,
  target: AppTarget
) -> SummondConfiguration {
  SummondConfiguration(bindings: [
    StoredBinding(shortcut: shortcut, target: target)
  ])
}

private func stored(
  id: UUID = UUID(),
  key: String,
  mods: [String],
  bundleID: String,
  mode: AppOpenMode = .launch
) throws -> StoredBinding {
  StoredBinding(
    id: id,
    shortcut: Shortcut(key: key, mods: mods),
    target: try AppTarget(bundleID: bundleID, mode: mode)
  )
}
