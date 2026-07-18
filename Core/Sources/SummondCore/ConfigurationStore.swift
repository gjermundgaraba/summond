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
      "Unsupported configuration schema version \(version)"
    case .invalid(let error):
      error.localizedDescription
    }
  }
}

public enum ConfigurationValidationError: Error, Equatable, Sendable {
  case invalidBinding(index: Int, error: BindingValidationError)
  case duplicateShortcut(index: Int, description: String)
}

extension ConfigurationValidationError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidBinding(let index, let error):
      "Configuration contains invalid binding #\(index): \(error.localizedDescription)"
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
    lock.withLock {
      data = encoded
    }
  }
}

public func validateConfiguration(_ configuration: SummondConfiguration) throws {
  try ConfigurationValidator.validate(configuration)
}

enum ConfigurationCodec {
  static func encode(_ configuration: SummondConfiguration) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(configuration)
  }

  static func decode(_ data: Data) -> ConfigurationLoadResult {
    let configuration: SummondConfiguration
    do {
      configuration = try JSONDecoder().decode(SummondConfiguration.self, from: data)
    } catch {
      return .corrupt(.undecodable(error.localizedDescription))
    }

    // schemaVersion is the durability hook: an unrecognized version is a
    // configuration written by a newer Summond, reported rather than misparsed.
    guard configuration.schemaVersion == SummondConfiguration.currentSchemaVersion else {
      return .corrupt(.unsupportedSchemaVersion(configuration.schemaVersion))
    }

    do {
      try ConfigurationValidator.validate(configuration)
    } catch let error as ConfigurationValidationError {
      return .corrupt(.invalid(error))
    } catch {
      return .corrupt(.undecodable(error.localizedDescription))
    }

    return .loaded(configuration)
  }
}

enum ConfigurationValidator {
  static func validate(_ configuration: SummondConfiguration) throws {
    var seenShortcuts: Set<CompiledShortcut> = []
    for (offset, binding) in configuration.bindings.enumerated() {
      let index = offset + 1
      guard !binding.target.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw ConfigurationValidationError.invalidBinding(index: index, error: .emptyBundleID)
      }

      let shortcut: CompiledShortcut
      do {
        shortcut = try BindingCompiler.compileShortcut(binding.shortcut)
      } catch let error as BindingValidationError {
        throw ConfigurationValidationError.invalidBinding(index: index, error: error)
      }

      guard seenShortcuts.insert(shortcut).inserted else {
        throw ConfigurationValidationError.duplicateShortcut(
          index: index, description: binding.shortcut.description)
      }
    }
  }
}
