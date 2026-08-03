import Foundation
import OSLog

public struct SummondConfiguration: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  // Read-only so an in-memory configuration can never carry a version other than
  // the current one; Codable decoding still populates it from persisted data, and
  // load() rejects any unsupported version it reads back.
  public private(set) var schemaVersion: Int
  public var bindings: [StoredBinding]
  public var verboseLogging: Bool

  public init(
    bindings: [StoredBinding] = [],
    verboseLogging: Bool = false
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.bindings = bindings
    self.verboseLogging = verboseLogging
  }

  public static var empty: SummondConfiguration {
    SummondConfiguration()
  }
}

public struct StoredBinding: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var shortcut: Shortcut
  public var target: AppTarget

  public init(id: UUID = UUID(), shortcut: Shortcut, target: AppTarget) {
    self.id = id
    self.shortcut = shortcut
    self.target = target
  }
}

public enum ConfigurationLoadResult: Equatable, Sendable {
  case fresh(SummondConfiguration)
  case loaded(SummondConfiguration)
  case corrupt(ConfigurationCorruption)
}

public enum ConfigurationCorruption: Error, Equatable, Sendable {
  case undecodable(String)
  case unsupportedSchemaVersion(Int)
  case invalid(ConfigurationValidationError)
}

extension ConfigurationCorruption: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .undecodable(let message):
      "Configuration data could not be decoded: \(message)"
    case .unsupportedSchemaVersion(let version):
      "This configuration uses schema version \(version), which this version of Summond cannot edit. Open it with a compatible Summond version. Your saved configuration has not been changed."
    case .invalid(let error):
      error.localizedDescription
    }
  }
}

public enum ConfigurationValidationError: Error, Equatable, Sendable {
  case invalidShortcut(index: Int, error: ShortcutValidationError)
  case invalidTarget(index: Int, error: AppTargetValidationError)
  case duplicateShortcut(index: Int, description: String)
}

extension ConfigurationValidationError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidShortcut(let index, let error):
      "Configuration contains invalid shortcut at binding #\(index): \(error.localizedDescription)"
    case .invalidTarget(let index, let error):
      "Configuration contains invalid target at binding #\(index): \(error.localizedDescription)"
    case .duplicateShortcut(let index, let description):
      "Configuration contains duplicate shortcut at binding #\(index): '\(description)'"
    }
  }
}

public protocol ConfigurationStore: Sendable {
  func load() -> ConfigurationLoadResult
  func save(_ configuration: SummondConfiguration) throws
}

public final class UserDefaultsConfigurationStore: @unchecked Sendable, ConfigurationStore {
  public static let defaultSuiteName = "net.garaba.summond.shared"
  public static let defaultKey = "configuration"

  private let defaults: UserDefaults
  private let key: String
  private let logger: Logger

  public convenience init?(
    suiteName: String = UserDefaultsConfigurationStore.defaultSuiteName,
    key: String = UserDefaultsConfigurationStore.defaultKey,
    logger: Logger = SummondLoggers.config
  ) {
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      return nil
    }

    self.init(defaults: defaults, key: key, logger: logger)
  }

  public init(
    defaults: UserDefaults,
    key: String = UserDefaultsConfigurationStore.defaultKey,
    logger: Logger = SummondLoggers.config
  ) {
    self.defaults = defaults
    self.key = key
    self.logger = logger
  }

  public func load() -> ConfigurationLoadResult {
    // The app and the agent run in separate processes sharing this suite. Pull
    // the latest committed value from cfprefsd before reading so a reload that
    // immediately follows the app's save observes the new configuration rather
    // than this process's cached copy.
    defaults.synchronize()
    guard let data = defaults.data(forKey: key) else {
      return .fresh(.empty)
    }

    let result = ConfigurationCodec.decode(data)
    if case .corrupt(let corruption) = result {
      logger.warning(
        "configuration load failed: \(corruption.localizedDescription, privacy: .private)"
      )
    }
    return result
  }

  public func save(_ configuration: SummondConfiguration) throws {
    try ConfigurationValidator.validate(configuration)
    defaults.synchronize()
    try ConfigurationCodec.rejectUnsupportedSchema(in: defaults.data(forKey: key))
    defaults.set(try ConfigurationCodec.encode(configuration), forKey: key)
    // Flush to cfprefsd synchronously so the agent process, prompted to reload
    // right after this returns, reads the value we just wrote (see load()).
    defaults.synchronize()
  }
}

public final class InMemoryConfigurationStore: @unchecked Sendable, ConfigurationStore {
  private let lock = NSLock()
  private var data: Data?

  public init(data: Data? = nil) {
    self.data = data
  }

  public func load() -> ConfigurationLoadResult {
    guard let data = lock.withLock({ data }) else {
      return .fresh(.empty)
    }

    return ConfigurationCodec.decode(data)
  }

  public func save(_ configuration: SummondConfiguration) throws {
    try ConfigurationValidator.validate(configuration)
    let encoded = try ConfigurationCodec.encode(configuration)
    try lock.withLock {
      try ConfigurationCodec.rejectUnsupportedSchema(in: data)
      data = encoded
    }
  }
}

enum ConfigurationCodec {
  private struct SchemaHeader: Decodable {
    let schemaVersion: Int
  }

  static func encode(_ configuration: SummondConfiguration) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(configuration)
  }

  static func decode(_ data: Data) -> ConfigurationLoadResult {
    let schemaVersion: Int
    do {
      schemaVersion = try JSONDecoder().decode(SchemaHeader.self, from: data).schemaVersion
    } catch {
      return .corrupt(.undecodable(error.localizedDescription))
    }

    // Check the schema before the v1 payload: a newer schema may remove or
    // reshape fields that SummondConfiguration currently requires.
    guard schemaVersion == SummondConfiguration.currentSchemaVersion else {
      return .corrupt(.unsupportedSchemaVersion(schemaVersion))
    }

    let configuration: SummondConfiguration
    do {
      configuration = try JSONDecoder().decode(SummondConfiguration.self, from: data)
    } catch {
      return .corrupt(.undecodable(error.localizedDescription))
    }

    do {
      try ConfigurationValidator.validate(configuration)
    } catch {
      return .corrupt(.invalid(error))
    }

    return .loaded(configuration)
  }

  static func rejectUnsupportedSchema(in data: Data?) throws {
    guard
      let data,
      let version = try? JSONDecoder().decode(SchemaHeader.self, from: data).schemaVersion,
      version != SummondConfiguration.currentSchemaVersion
    else {
      return
    }

    throw ConfigurationCorruption.unsupportedSchemaVersion(version)
  }
}

enum ConfigurationValidator {
  static func validate(_ configuration: SummondConfiguration) throws(ConfigurationValidationError) {
    var seenShortcuts: Set<CompiledShortcut> = []
    for (offset, binding) in configuration.bindings.enumerated() {
      let index = offset + 1
      guard !binding.target.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw .invalidTarget(index: index, error: .emptyBundleID)
      }

      let shortcut: CompiledShortcut
      do {
        shortcut = try BindingCompiler.compileShortcut(binding.shortcut)
      } catch {
        throw .invalidShortcut(index: index, error: error)
      }

      guard seenShortcuts.insert(shortcut).inserted else {
        throw .duplicateShortcut(
          index: index, description: binding.shortcut.description)
      }
    }
  }
}
