import CoreGraphics
import Foundation

enum BindingCompilationError: Error, Equatable {
  case validation(BindingValidationError)
  case unresolvedBundleID(String)
}

struct CompiledShortcut: Sendable, Equatable, Hashable {
  let keyCode: CGKeyCode
  let modifiers: CGEventFlags

  func hash(into hasher: inout Hasher) {
    hasher.combine(keyCode)
    hasher.combine(modifiers.rawValue)
  }
}

struct CompiledAppBinding: Sendable, Equatable {
  let binding: AppBinding
  let shortcut: CompiledShortcut
  let identity: AppIdentity

  var description: String {
    binding.description
  }
}

struct BindingSnapshot: Sendable {
  let bindingsByTrigger: [CompiledShortcut: CompiledAppBinding]

  static let empty = BindingSnapshot(bindingsByTrigger: [:])

  func match(keyCode: CGKeyCode, modifiers: CGEventFlags) -> CompiledAppBinding? {
    binding(for: CompiledShortcut(keyCode: keyCode, modifiers: modifiers))
  }

  func binding(for shortcut: CompiledShortcut) -> CompiledAppBinding? {
    bindingsByTrigger[shortcut]
  }

  var count: Int {
    bindingsByTrigger.count
  }
}

enum BindingCompiler {
  static func compileShortcut(_ shortcut: Shortcut) throws -> CompiledShortcut {
    guard let keyCode = KeyCode.resolve(shortcut.key) else {
      throw BindingValidationError.unknownKey(shortcut.key)
    }

    guard let modifiers = KeyCode.resolveModifiers(shortcut.mods) else {
      let invalid = shortcut.mods.filter { KeyCode.resolveModifiers([$0]) == nil }
      throw BindingValidationError.unknownModifiers(invalid)
    }

    return CompiledShortcut(keyCode: keyCode, modifiers: modifiers)
  }

  static func compileBinding(
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

  static func compileBindings(
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
}
