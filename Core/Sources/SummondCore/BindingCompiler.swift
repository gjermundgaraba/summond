import CoreGraphics
import Foundation

public enum BindingCompilationError: Error, Equatable, Sendable {
  case validation(BindingValidationError)
  case unresolvedBundleID(String)
}

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

  public var description: String {
    binding.description
  }
}

public struct BindingSnapshot: Sendable {
  public let bindingsByTrigger: [CompiledShortcut: CompiledAppBinding]

  public static let empty = BindingSnapshot(bindingsByTrigger: [:])

  public init(bindingsByTrigger: [CompiledShortcut: CompiledAppBinding]) {
    self.bindingsByTrigger = bindingsByTrigger
  }

  public func match(keyCode: CGKeyCode, modifiers: CGEventFlags) -> CompiledAppBinding? {
    binding(for: CompiledShortcut(keyCode: keyCode, modifiers: modifiers))
  }

  public func binding(for shortcut: CompiledShortcut) -> CompiledAppBinding? {
    bindingsByTrigger[shortcut]
  }

  public var count: Int {
    bindingsByTrigger.count
  }
}

public enum BindingCompiler {
  public typealias UnresolvedBinding = (index: Int, bundleID: String)

  public static func compileShortcut(_ shortcut: Shortcut) throws -> CompiledShortcut {
    guard let keyCode = KeyCode.resolve(shortcut.key) else {
      throw BindingValidationError.unknownKey(shortcut.key)
    }

    guard let modifiers = KeyCode.resolveModifiers(shortcut.mods) else {
      let invalid = shortcut.mods.filter { KeyCode.resolveModifiers([$0]) == nil }
      throw BindingValidationError.unknownModifiers(invalid)
    }

    return CompiledShortcut(keyCode: keyCode, modifiers: modifiers)
  }

  public static func compileBinding(
    _ binding: AppBinding,
    appResolver: any AppResolver
  ) throws -> CompiledAppBinding {
    let shortcut: CompiledShortcut
    do {
      shortcut = try compileShortcut(binding.shortcut)
    } catch let error as BindingValidationError {
      throw BindingCompilationError.validation(error)
    }

    guard let identity = appResolver.resolve(bundleID: binding.app.bundleID) else {
      throw BindingCompilationError.unresolvedBundleID(binding.app.bundleID)
    }

    return CompiledAppBinding(binding: binding, shortcut: shortcut, identity: identity)
  }

  public static func compileBindings(
    _ bindings: [AppBinding],
    appResolver: any AppResolver
  ) throws -> BindingSnapshot {
    var compiledBindings: [CompiledShortcut: CompiledAppBinding] = [:]

    for (offset, binding) in bindings.enumerated() {
      let index = offset + 1
      let compiledBinding: CompiledAppBinding
      do {
        compiledBinding = try compileBinding(binding, appResolver: appResolver)
      } catch let error as BindingCompilationError {
        switch error {
        case .validation(let validationError):
          throw BindingConfigError.invalidBinding(index: index, error: validationError)
        case .unresolvedBundleID(let bundleID):
          throw BindingConfigError.unresolvedBundleID(index: index, bundleID: bundleID)
        }
      }

      if compiledBindings[compiledBinding.shortcut] != nil {
        throw BindingConfigError.duplicateShortcut(
          index: index,
          description: compiledBinding.description
        )
      }

      compiledBindings[compiledBinding.shortcut] = compiledBinding
    }

    return BindingSnapshot(bindingsByTrigger: compiledBindings)
  }

  public static func compileBindingsSkippingUnresolved(
    _ bindings: [AppBinding],
    appResolver: any AppResolver
  ) throws -> (snapshot: BindingSnapshot, unresolved: [UnresolvedBinding]) {
    var compiledBindings: [CompiledShortcut: CompiledAppBinding] = [:]
    var seenShortcuts: Set<CompiledShortcut> = []
    var unresolved: [UnresolvedBinding] = []

    for (offset, binding) in bindings.enumerated() {
      let index = offset + 1
      let shortcut: CompiledShortcut
      do {
        shortcut = try compileShortcut(binding.shortcut)
      } catch let error as BindingValidationError {
        throw BindingConfigError.invalidBinding(index: index, error: error)
      }

      if seenShortcuts.contains(shortcut) {
        throw BindingConfigError.duplicateShortcut(
          index: index,
          description: binding.description
        )
      }
      seenShortcuts.insert(shortcut)

      guard let identity = appResolver.resolve(bundleID: binding.app.bundleID) else {
        unresolved.append((index: index, bundleID: binding.app.bundleID))
        continue
      }

      compiledBindings[shortcut] = CompiledAppBinding(
        binding: binding,
        shortcut: shortcut,
        identity: identity
      )
    }

    return (BindingSnapshot(bindingsByTrigger: compiledBindings), unresolved)
  }
}
