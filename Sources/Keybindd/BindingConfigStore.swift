import CoreGraphics
import Foundation

enum BindingSelector: Sendable {
  case key(keyCode: CGKeyCode, description: String)
  case shortcut(CompiledShortcut, description: String)

  var description: String {
    switch self {
    case .key(_, let description), .shortcut(_, let description):
      description
    }
  }
}

enum BindingConfigStore {
  static func load(
    from path: String,
    appResolver: any AppResolver = InstalledAppResolver()
  ) throws -> BindingConfigLoadResult {
    let bindings = try BindingConfigDocument.parse(read(from: path))
    let snapshot = try BindingCompiler.compileBindings(bindings, appResolver: appResolver)
    return BindingConfigLoadResult(bindings: bindings, snapshot: snapshot)
  }

  @discardableResult
  static func ensureExists(at path: String, logger: Logger = Logger()) -> Bool {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: path) {
      return false
    }

    do {
      if let parentDirectory = parentDirectory(for: path) {
        try fileManager.createDirectory(atPath: parentDirectory, withIntermediateDirectories: true)
      }
      try BindingConfigDocument.serialize([]).write(toFile: path, atomically: true, encoding: .utf8)
      return true
    } catch {
      logger.warning("failed to create config at '\(path)': \(error.localizedDescription)")
      return false
    }
  }

  static func add(
    _ binding: AppBinding,
    to path: String,
    resolver: any AppResolver,
    logger: Logger = Logger()
  ) throws -> AppBinding {
    let compiledBinding: CompiledAppBinding
    do {
      compiledBinding = try BindingCompiler.compileBinding(binding, appResolver: resolver)
    } catch let error as BindingCompilationError {
      switch error {
      case .validation(let validationError):
        throw validationError
      case .unresolvedBundleID(let bundleID):
        throw BindingEditError.unresolvedBundleID(bundleID)
      }
    }

    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: path), !ensureExists(at: path, logger: logger) {
      throw BindingEditError.fileAccess("Failed to create config at '\(path)'")
    }

    let existingConfig = try loadForEdit(from: path, appResolver: resolver)

    if let existing = existingConfig.snapshot.binding(for: compiledBinding.shortcut) {
      throw BindingEditError.duplicateBinding(existing.description)
    }

    try saveForEdit(existingConfig.bindings + [binding], to: path)
    return binding
  }

  static func remove(
    _ selector: BindingSelector,
    from path: String,
    appResolver: any AppResolver = InstalledAppResolver()
  ) throws -> AppBinding {
    let existingConfig = try loadForEdit(from: path, appResolver: appResolver)

    guard !existingConfig.bindings.isEmpty else {
      throw BindingEditError.emptyConfig
    }

    let matches = try existingConfig.bindings.enumerated().filter { offset, existingBinding in
      let existingShortcut: CompiledShortcut
      do {
        existingShortcut = try BindingCompiler.compileShortcut(existingBinding.shortcut)
      } catch let error as BindingValidationError {
        throw BindingEditError.invalidConfig(.invalidBinding(index: offset + 1, error: error))
      }

      switch selector {
      case .key(let keyCode, _):
        return existingShortcut.keyCode == keyCode
      case .shortcut(let shortcut, _):
        return existingShortcut == shortcut
      }
    }

    guard !matches.isEmpty else {
      throw BindingEditError.noMatch(selector.description)
    }

    if matches.count > 1, case .key = selector {
      throw BindingEditError.ambiguousMatch(selector.description)
    }

    let removedIndex = matches[0].offset
    var remainingBindings = existingConfig.bindings
    let removed = remainingBindings.remove(at: removedIndex)
    try saveForEdit(remainingBindings, to: path)
    return removed
  }

  private static func loadForEdit(
    from path: String,
    appResolver: any AppResolver
  ) throws -> BindingConfigLoadResult {
    do {
      return try load(from: path, appResolver: appResolver)
    } catch let error as BindingConfigError {
      throw BindingEditError.invalidConfig(error)
    } catch {
      throw BindingEditError.fileAccess(
        "Failed to read config at '\(path)': \(error.localizedDescription)"
      )
    }
  }

  private static func saveForEdit(_ bindings: [AppBinding], to path: String) throws {
    do {
      try save(bindings, to: path)
    } catch {
      throw BindingEditError.fileAccess(
        "Failed to write config at '\(path)': \(error.localizedDescription)"
      )
    }
  }

  private static func read(from path: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: path))
  }

  private static func save(_ bindings: [AppBinding], to path: String) throws {
    try BindingConfigDocument.serialize(bindings).write(
      toFile: path, atomically: true, encoding: .utf8)
  }

  private static func parentDirectory(for path: String) -> String? {
    let directory = (path as NSString).deletingLastPathComponent
    return directory.isEmpty ? nil : directory
  }
}
