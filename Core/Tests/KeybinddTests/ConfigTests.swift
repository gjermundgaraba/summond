import CoreGraphics
import Foundation
import Testing

@testable import KeybinddCore

@Suite("Configuration store")
struct ConfigurationStoreTests {
  @Test("Missing data loads as a fresh empty configuration")
  func absentDataLoadsFresh() {
    let result = InMemoryConfigurationStore().load()

    #expect(result == .fresh(.empty))
    #expect(result.configuration?.bindings.isEmpty == true)
  }

  @Test("Shared defaults suite is not any product bundle identifier")
  func sharedDefaultsSuiteDoesNotMatchBundleIdentifiers() {
    let bundleIdentifiers = [
      KeybinddBundleIdentifiers.app,
      KeybinddBundleIdentifiers.agent,
      KeybinddBundleIdentifiers.statusItem,
    ]

    for bundleIdentifier in bundleIdentifiers {
      #expect(UserDefaultsConfigurationStore.defaultSuiteName != bundleIdentifier)
    }
  }

  @Test("User defaults store round trips across instances in the same suite")
  func userDefaultsStoreRoundTripsAcrossInstances() throws {
    let suiteName = "net.garaba.keybindd.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }

    let writer = try #require(UserDefaultsConfigurationStore(suiteName: suiteName))
    let reader = try #require(UserDefaultsConfigurationStore(suiteName: suiteName))
    let bindingID = try #require(UUID(uuidString: "A30A2D05-2481-4C28-8F61-30475F64C391"))
    let configuration = KeybinddConfigurationV1(
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

  @Test("JSON round trip preserves binding UUIDs")
  func jsonRoundTripPreservesIDs() throws {
    let id = UUID()
    let configuration = KeybinddConfigurationV1(
      bindings: [
        StoredBinding(
          id: id,
          shortcut: Shortcut(key: "F5", mods: ["CMD", "Shift"]),
          target: try AppTarget(bundleID: "com.apple.Safari", mode: .newWindow)
        )
      ],
      verboseLogging: true
    )
    let store = InMemoryConfigurationStore()

    try store.save(configuration)
    let loaded = try #require(store.load().configuration)

    #expect(loaded == configuration)
    #expect(loaded.bindings[0].id == id)
    #expect(loaded.bindings[0].shortcut.key == "f5")
    #expect(loaded.bindings[0].shortcut.mods == ["cmd", "shift"])
    #expect(loaded.verboseLogging == true)
  }

  @Test("Garbage data loads as corrupt")
  func garbageDataLoadsCorrupt() {
    let store = InMemoryConfigurationStore(data: Data([0xFF]))

    guard case .corrupt(.undecodable) = store.load() else {
      Issue.record("Expected undecodable corruption")
      return
    }
  }

  @Test("Wrong schema version loads as corrupt")
  func wrongSchemaVersionLoadsCorrupt() throws {
    let data = try JSONEncoder().encode(
      KeybinddConfigurationV1(schemaVersion: 2, bindings: [], verboseLogging: false)
    )
    let store = InMemoryConfigurationStore(data: data)

    #expect(store.load() == .corrupt(.unsupportedSchemaVersion(2)))
  }

  @Test("Save rejects invalid configurations")
  func saveRejectsInvalidConfigurations() throws {
    let cases: [(KeybinddConfigurationV1, ConfigurationValidationError)] = [
      (
        configuration(
          shortcut: Shortcut(key: "nonexistent", mods: ["cmd"]),
          target: try AppTarget(bundleID: "com.apple.Safari", mode: .launch)
        ),
        .invalidBinding(index: 1, error: .unknownKey("nonexistent"))
      ),
      (
        configuration(
          shortcut: Shortcut(key: "a", mods: ["cmd", "super"]),
          target: try AppTarget(bundleID: "com.apple.Safari", mode: .launch)
        ),
        .invalidBinding(index: 1, error: .unknownModifiers(["super"]))
      ),
      (
        configuration(
          shortcut: Shortcut(key: "a", mods: ["cmd"]),
          target: AppTarget(uncheckedBundleID: "", mode: .launch)
        ),
        .invalidBinding(index: 1, error: .emptyBundleID)
      ),
      (
        KeybinddConfigurationV1(
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

  @Test("Derives app bindings without resolving installed apps")
  func derivesAppBindings() throws {
    let configuration = KeybinddConfigurationV1(
      bindings: [
        try stored(
          id: UUID(),
          key: "space",
          mods: ["cmd"],
          bundleID: "com.example.NotInstalled",
          mode: .move
        )
      ]
    )

    let bindings = appBindings(from: configuration)

    #expect(
      bindings == [
        AppBinding(
          shortcut: Shortcut(key: "space", mods: ["cmd"]),
          app: try AppTarget(bundleID: "com.example.NotInstalled", mode: .move)
        )
      ])
  }

  @Test("Modifier-less shortcut validates and round trips through JSON")
  func modifierLessShortcutValidatesAndRoundTrips() throws {
    let id = UUID()
    let configuration = KeybinddConfigurationV1(
      bindings: [
        try stored(
          id: id,
          key: "f5",
          mods: [],
          bundleID: "com.apple.Safari"
        )
      ]
    )
    let store = InMemoryConfigurationStore()

    try validateConfiguration(configuration)
    try store.save(configuration)
    let loaded = try #require(store.load().configuration)

    #expect(loaded.bindings[0].id == id)
    #expect(loaded.bindings[0].shortcut == Shortcut(key: "f5", mods: []))
  }
}

@Suite("App open mode")
struct AppOpenModeTests {
  @Test("Parses hyphenated and raw-value spellings")
  func parsesSpellings() throws {
    #expect(try AppOpenMode(parsing: "launch") == .launch)
    #expect(try AppOpenMode(parsing: "new-window") == .newWindow)
    #expect(try AppOpenMode(parsing: "new_window") == .newWindow)
    #expect(try AppOpenMode(parsing: "MOVE") == .move)
  }

  @Test("Rejects unknown modes")
  func rejectsUnknownModes() {
    #expect(throws: BindingValidationError.unknownMode("focus")) {
      try AppOpenMode(parsing: "focus")
    }
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

  @Test("Modifier-less shortcut compiles and matches empty modifier events")
  func modifierLessShortcutCompilesAndMatches() throws {
    let snapshot = try BindingCompiler.compileBindings(
      [try makeBinding(key: "f5", mods: [], bundleID: "com.apple.safari")],
      appResolver: TestAppResolver(appsByBundleID: [
        "com.apple.safari": makeIdentity(bundleID: "com.apple.safari")
      ])
    )

    let match = snapshot.match(keyCode: 0x60, modifiers: CGEventFlags())

    #expect(match?.identity.bundleIdentifier == "com.apple.safari")
    #expect(match?.binding.shortcut.mods == [])
  }

  @Test("Modifier-less and modified shortcuts on the same key are distinct")
  func modifierLessAndModifiedSameKeyAreDistinct() throws {
    let snapshot = try BindingCompiler.compileBindings(
      [
        try makeBinding(key: "f5", mods: [], bundleID: "com.apple.safari"),
        try makeBinding(key: "f5", mods: ["cmd"], bundleID: "com.apple.Terminal"),
      ],
      appResolver: TestAppResolver(appsByBundleID: [
        "com.apple.safari": makeIdentity(bundleID: "com.apple.safari"),
        "com.apple.Terminal": makeIdentity(bundleID: "com.apple.Terminal"),
      ])
    )

    #expect(snapshot.count == 2)
    #expect(
      snapshot.match(keyCode: 0x60, modifiers: CGEventFlags())?.identity.bundleIdentifier
        == "com.apple.safari"
    )
    #expect(
      snapshot.match(keyCode: 0x60, modifiers: .maskCommand)?.identity.bundleIdentifier
        == "com.apple.Terminal"
    )
  }
}

private func configuration(
  shortcut: Shortcut,
  target: AppTarget
) -> KeybinddConfigurationV1 {
  KeybinddConfigurationV1(bindings: [
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
