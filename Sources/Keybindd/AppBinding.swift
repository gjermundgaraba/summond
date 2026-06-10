import Foundation

enum BindingValidationError: Error, Equatable {
  case unknownKey(String)
  case unknownModifiers([String])
  case unknownMode(String)
  case emptyBundleID
}

extension BindingValidationError: LocalizedError {
  var errorDescription: String? {
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

enum BindingConfigError: Error, Equatable {
  case invalidDocument(String)
  case invalidBinding(index: Int, error: BindingValidationError)
  case duplicateShortcut(index: Int, description: String)
  case unresolvedBundleID(index: Int, bundleID: String)
}

extension BindingConfigError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .invalidDocument(let message):
      message
    case .invalidBinding(let index, let error):
      "Config contains invalid binding #\(index): \(error.localizedDescription)"
    case .duplicateShortcut(let index, let description):
      "Config contains duplicate shortcut at binding #\(index): '\(description)'"
    case .unresolvedBundleID(let index, let bundleID):
      "Config contains unresolved bundle ID at binding #\(index): '\(bundleID)' is not installed"
    }
  }
}

enum BindingEditError: Error, Equatable {
  case invalidConfig(BindingConfigError)
  case fileAccess(String)
  case unresolvedBundleID(String)
  case duplicateBinding(String)
  case emptyConfig
  case noMatch(String)
  case ambiguousMatch(String)
}

extension BindingEditError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .invalidConfig(let error):
      error.localizedDescription
    case .fileAccess(let message):
      message
    case .unresolvedBundleID(let bundleID):
      "Bundle ID '\(bundleID)' is not installed"
    case .duplicateBinding(let description):
      "Binding for '\(description)' already exists"
    case .emptyConfig:
      "Config has no bindings to remove"
    case .noMatch(let description):
      "No binding found matching '\(description)'"
    case .ambiguousMatch(let description):
      "Multiple bindings match '\(description)'. Specify --mods to disambiguate."
    }
  }
}

enum AppOpenMode: String, Sendable, Equatable, CaseIterable {
  case launch
  case newWindow = "new_window"
  case move

  var cliValue: String {
    rawValue.replacingOccurrences(of: "_", with: "-")
  }

  init(parsing value: String) throws {
    let normalized = value.lowercased().replacingOccurrences(of: "-", with: "_")
    guard let mode = AppOpenMode(rawValue: normalized) else {
      throw BindingValidationError.unknownMode(value)
    }

    self = mode
  }
}

struct Shortcut: Sendable, Equatable {
  let key: String
  let mods: [String]

  init(key: String, mods: [String]) {
    self.key = key.lowercased()
    self.mods = mods.map { $0.lowercased() }
  }

  var description: String {
    (mods + [key]).joined(separator: "+")
  }
}

struct AppTarget: Sendable, Equatable {
  let bundleID: String
  let mode: AppOpenMode

  init(bundleID: String, mode: AppOpenMode) throws {
    let trimmedBundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedBundleID.isEmpty else {
      throw BindingValidationError.emptyBundleID
    }

    self.bundleID = trimmedBundleID
    self.mode = mode
  }
}

struct AppBinding: Sendable, Equatable {
  let shortcut: Shortcut
  let app: AppTarget

  var description: String {
    shortcut.description
  }
}
