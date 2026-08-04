import Foundation

public struct SummondConfiguration: Codable, Equatable, Sendable {
  public var bindings: [StoredBinding]
  public var verboseLogging: Bool

  public init(
    bindings: [StoredBinding] = [],
    verboseLogging: Bool = false
  ) {
    self.bindings = bindings
    self.verboseLogging = verboseLogging
  }

  public static let empty = SummondConfiguration()
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

public enum ConfigurationCorruption: Error, Equatable, Sendable {
  case undecodable(String)
  case invalid(ConfigurationValidationError)
}

extension ConfigurationCorruption: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .undecodable(let message):
      "Configuration data could not be decoded: \(message)"
    case .invalid(let error):
      error.localizedDescription
    }
  }
}

public enum ConfigurationValidationError: Error, Equatable, Sendable {
  case duplicateID(index: Int)
  case invalidShortcut(index: Int, error: ShortcutValidationError)
  case invalidTarget(index: Int, error: AppTargetValidationError)
  case duplicateShortcut(index: Int, description: String)
}

extension ConfigurationValidationError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .duplicateID(let index):
      "Configuration contains duplicate identifier at binding #\(index)"
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
  func load() throws -> SummondConfiguration?
  func save(_ configuration: SummondConfiguration) throws
  func replace(with configuration: SummondConfiguration) throws
}

public struct FileConfigurationStore: ConfigurationStore {
  public static let defaultURL = URL.applicationSupportDirectory
    .appendingPathComponent("Summond", isDirectory: true)
    .appendingPathComponent("configuration.json")

  public let url: URL

  public init(url: URL = FileConfigurationStore.defaultURL) {
    self.url = url
  }

  public func load() throws -> SummondConfiguration? {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return nil
    }
    return try ConfigurationCodec.decode(data)
  }

  public func save(_ configuration: SummondConfiguration) throws {
    try ConfigurationValidator.validate(configuration)
    _ = try load()
    try write(configuration)
  }

  public func replace(with configuration: SummondConfiguration) throws {
    try ConfigurationValidator.validate(configuration)
    try write(configuration)
  }

  private func write(_ configuration: SummondConfiguration) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try ConfigurationCodec.encode(configuration).write(to: url, options: .atomic)
  }
}

public final class InMemoryConfigurationStore: @unchecked Sendable, ConfigurationStore {
  private let lock = NSLock()
  private var data: Data?

  public init(data: Data? = nil) {
    self.data = data
  }

  public func load() throws -> SummondConfiguration? {
    guard let data = lock.withLock({ data }) else {
      return nil
    }
    return try ConfigurationCodec.decode(data)
  }

  public func save(_ configuration: SummondConfiguration) throws {
    try ConfigurationValidator.validate(configuration)
    let encoded = try ConfigurationCodec.encode(configuration)
    try lock.withLock {
      if let data {
        _ = try ConfigurationCodec.decode(data)
      }
      data = encoded
    }
  }

  public func replace(with configuration: SummondConfiguration) throws {
    try ConfigurationValidator.validate(configuration)
    let encoded = try ConfigurationCodec.encode(configuration)
    lock.withLock {
      data = encoded
    }
  }
}

enum ConfigurationCodec {
  static func encode(_ configuration: SummondConfiguration) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(configuration)
  }

  static func decode(_ data: Data) throws -> SummondConfiguration {
    let configuration: SummondConfiguration
    do {
      configuration = try JSONDecoder().decode(SummondConfiguration.self, from: data)
    } catch {
      throw ConfigurationCorruption.undecodable(error.localizedDescription)
    }

    do {
      try ConfigurationValidator.validate(configuration)
    } catch {
      throw ConfigurationCorruption.invalid(error)
    }
    return configuration
  }
}

enum ConfigurationValidator {
  static func validate(_ configuration: SummondConfiguration) throws(ConfigurationValidationError) {
    var seenIDs: Set<UUID> = []
    var seenShortcuts: Set<CompiledShortcut> = []
    for (offset, binding) in configuration.bindings.enumerated() {
      let index = offset + 1
      guard seenIDs.insert(binding.id).inserted else {
        throw .duplicateID(index: index)
      }
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
