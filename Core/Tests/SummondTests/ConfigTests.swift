import CoreGraphics
import Foundation
import Testing

@testable import SummondCore

@Suite("Configuration store")
struct ConfigurationStoreTests {
  @Test("Missing data loads as a fresh empty configuration")
  func absentDataLoadsFresh() throws {
    #expect(try InMemoryConfigurationStore().load() == nil)
  }

  @Test("File store round trips across instances")
  func fileStoreRoundTripsAcrossInstances() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("configuration.json")
    let writer = FileConfigurationStore(url: url)
    let reader = FileConfigurationStore(url: url)
    #expect(try reader.load() == nil)

    try writer.save(.empty)

    #expect(try reader.load() == .empty)
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

    #expect(try store.load() == configuration)
  }

  @Test("Garbage data throws typed corruption")
  func garbageDataThrowsCorruption() {
    let store = InMemoryConfigurationStore(data: Data([0xFF]))

    #expect(throws: ConfigurationCorruption.self) {
      try store.load()
    }
  }

  @Test("Save refuses to overwrite corrupt data")
  func saveRefusesToOverwriteCorruptData() {
    let store = InMemoryConfigurationStore(data: Data([0xFF]))

    #expect(throws: ConfigurationCorruption.self) {
      try store.save(.empty)
    }
    #expect(throws: ConfigurationCorruption.self) {
      try store.load()
    }
  }

  @Test("Explicit replacement overwrites corrupt data")
  func replacementOverwritesCorruptData() throws {
    let store = InMemoryConfigurationStore(data: Data([0xFF]))

    try store.replace(with: .empty)

    #expect(try store.load() == .empty)
  }

  @Test("Save rejects invalid configurations")
  func saveRejectsInvalidConfigurations() throws {
    let duplicateID = UUID()
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
      (
        SummondConfiguration(
          bindings: [
            try stored(
              id: duplicateID,
              key: "f5",
              mods: ["cmd"],
              bundleID: "com.apple.Safari"
            ),
            try stored(
              id: duplicateID,
              key: "f6",
              mods: ["cmd"],
              bundleID: "com.apple.Terminal"
            ),
          ]
        ),
        .duplicateID(index: 2)
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

    #expect(try store.load() == configuration)
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

  @Test("Compiling reports each unresolved bundle ID once")
  func deduplicatesUnresolvedBundleIDs() throws {
    let compiled = try BindingCompiler.compile(
      [
        try makeBinding(key: "f5", bundleID: "com.example.missing"),
        try makeBinding(key: "f6", bundleID: "com.example.missing"),
      ],
      appResolver: TestAppResolver(appsByBundleID: [:])
    )

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
