import CoreGraphics
import Foundation

public struct CompiledShortcut: Sendable, Equatable, Hashable {
  public let keyCode: CGKeyCode
  public let modifiers: CGEventFlags

  public init(keyCode: CGKeyCode, modifiers: CGEventFlags) {
    self.keyCode = keyCode
    self.modifiers = modifiers
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(keyCode)
    hasher.combine(modifiers.rawValue)
  }
}

public struct CompiledAppBinding: Sendable, Equatable {
  public let binding: AppBinding
  public let shortcut: CompiledShortcut
  public let identity: AppIdentity

  public init(binding: AppBinding, shortcut: CompiledShortcut, identity: AppIdentity) {
    self.binding = binding
    self.shortcut = shortcut
    self.identity = identity
  }
}

public struct BindingSnapshot: Sendable {
  public let bindingsByTrigger: [CompiledShortcut: CompiledAppBinding]

  public static let empty = BindingSnapshot(bindingsByTrigger: [:])

  public init(bindingsByTrigger: [CompiledShortcut: CompiledAppBinding]) {
    self.bindingsByTrigger = bindingsByTrigger
  }

  public func match(keyCode: CGKeyCode, modifiers: CGEventFlags) -> CompiledAppBinding? {
    bindingsByTrigger[CompiledShortcut(keyCode: keyCode, modifiers: modifiers)]
  }

  public var count: Int {
    bindingsByTrigger.count
  }
}

/// The outcome of compiling a configuration's bindings: the active snapshot the
/// engine installs, plus the bundle IDs that could not be resolved to an
/// installed app. Unresolved bundles are degraded state, not an error — the
/// resolvable bindings still compile and run.
public struct CompiledBindings: Sendable {
  public let snapshot: BindingSnapshot
  public let unresolvedBundleIDs: [String]

  public init(snapshot: BindingSnapshot, unresolvedBundleIDs: [String]) {
    self.snapshot = snapshot
    self.unresolvedBundleIDs = unresolvedBundleIDs
  }
}

public enum BindingCompiler {
  public static func compileShortcut(_ shortcut: Shortcut) throws(ShortcutValidationError)
    -> CompiledShortcut
  {
    guard let keyCode = KeyCode.resolve(shortcut.key) else {
      throw .unknownKey(shortcut.key)
    }

    guard let modifiers = KeyCode.resolveModifiers(shortcut.mods) else {
      let invalid = shortcut.mods.filter { KeyCode.resolveModifiers([$0]) == nil }
      throw .unknownModifiers(invalid)
    }

    return CompiledShortcut(keyCode: keyCode, modifiers: modifiers)
  }

  /// Compiles bindings into the active snapshot, skipping (but reporting) any
  /// whose bundle ID is not installed. Structurally invalid bindings — an
  /// unknown key/modifier or a duplicate shortcut — throw.
  public static func compile(
    _ bindings: [AppBinding],
    appResolver: any AppResolver
  ) throws(ConfigurationValidationError) -> CompiledBindings {
    var compiledBindings: [CompiledShortcut: CompiledAppBinding] = [:]
    var seenShortcuts: Set<CompiledShortcut> = []
    var unresolvedBundleIDs: [String] = []

    for (offset, binding) in bindings.enumerated() {
      let index = offset + 1
      let shortcut: CompiledShortcut
      do {
        shortcut = try compileShortcut(binding.shortcut)
      } catch {
        throw .invalidShortcut(index: index, error: error)
      }

      guard seenShortcuts.insert(shortcut).inserted else {
        throw .duplicateShortcut(
          index: index,
          description: binding.shortcut.description
        )
      }

      guard let identity = appResolver.resolve(bundleID: binding.app.bundleID) else {
        unresolvedBundleIDs.append(binding.app.bundleID)
        continue
      }

      compiledBindings[shortcut] = CompiledAppBinding(
        binding: binding,
        shortcut: shortcut,
        identity: identity
      )
    }

    return CompiledBindings(
      snapshot: BindingSnapshot(bindingsByTrigger: compiledBindings),
      unresolvedBundleIDs: unresolvedBundleIDs
    )
  }
}
