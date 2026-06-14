import Foundation

public enum BindingValidationError: Error, Equatable, Sendable {
  case unknownKey(String)
  case unknownModifiers([String])
  case unknownMode(String)
  case emptyBundleID
}

extension BindingValidationError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .unknownKey(let key):
      "Unknown key '\(key)'"
    case .unknownModifiers(let modifiers):
      "Unknown modifier(s): \(modifiers.joined(separator: ", "))"
    case .unknownMode(let mode):
      "Unknown mode '\(mode)'"
    case .emptyBundleID:
      "Bundle ID cannot be empty"
    }
  }
}

public enum BindingConfigError: Error, Equatable, Sendable {
  case invalidBinding(index: Int, error: BindingValidationError)
  case duplicateShortcut(index: Int, description: String)
  case unresolvedBundleID(index: Int, bundleID: String)
}

extension BindingConfigError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidBinding(let index, let error):
      "Config contains invalid binding #\(index): \(error.localizedDescription)"
    case .duplicateShortcut(let index, let description):
      "Config contains duplicate shortcut at binding #\(index): '\(description)'"
    case .unresolvedBundleID(let index, let bundleID):
      "Config contains unresolved bundle ID at binding #\(index): '\(bundleID)' is not installed"
    }
  }
}

public enum AppOpenMode: String, Codable, Sendable, Equatable, CaseIterable {
  case launch
  case newWindow = "new_window"
  case move

  public init(parsing value: String) throws {
    let normalized = value.lowercased().replacingOccurrences(of: "-", with: "_")
    guard let mode = AppOpenMode(rawValue: normalized) else {
      throw BindingValidationError.unknownMode(value)
    }

    self = mode
  }
}

public struct Shortcut: Codable, Sendable, Equatable {
  public var key: String
  public var mods: [String]

  public init(key: String, mods: [String]) {
    self.key = key.lowercased()
    self.mods = mods.map { $0.lowercased() }
  }

  public var description: String {
    (mods + [key]).joined(separator: "+")
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      key: try container.decode(String.self, forKey: .key),
      mods: try container.decode([String].self, forKey: .mods)
    )
  }
}

public struct AppTarget: Codable, Sendable, Equatable {
  public var bundleID: String
  public var mode: AppOpenMode

  public init(bundleID: String, mode: AppOpenMode) throws {
    let trimmedBundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedBundleID.isEmpty else {
      throw BindingValidationError.emptyBundleID
    }

    self.bundleID = trimmedBundleID
    self.mode = mode
  }

  init(uncheckedBundleID bundleID: String, mode: AppOpenMode) {
    self.bundleID = bundleID
    self.mode = mode
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      uncheckedBundleID: try container.decode(String.self, forKey: .bundleID),
      mode: try container.decode(AppOpenMode.self, forKey: .mode)
    )
  }
}

public struct AppBinding: Sendable, Equatable {
  public var shortcut: Shortcut
  public var app: AppTarget

  public init(shortcut: Shortcut, app: AppTarget) {
    self.shortcut = shortcut
    self.app = app
  }

  public var description: String {
    shortcut.description
  }
}
