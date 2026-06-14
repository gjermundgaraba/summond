@preconcurrency import CoreGraphics
import Foundation
import OSLog

public enum KeyEventEngineError: Error, Equatable, Sendable {
  case eventTapInstallationFailed
}

extension KeyEventEngineError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .eventTapInstallationFailed:
      "Failed to create event tap. Grant Accessibility permission in System Settings."
    }
  }
}

public struct KeyEventEngineStatus: Equatable, Sendable {
  public let isTapInstalled: Bool
  public let isTapEnabled: Bool
  public let wasDisabledByTimeout: Bool
  public let wasDisabledByUserInput: Bool

  public init(
    isTapInstalled: Bool,
    isTapEnabled: Bool,
    wasDisabledByTimeout: Bool,
    wasDisabledByUserInput: Bool
  ) {
    self.isTapInstalled = isTapInstalled
    self.isTapEnabled = isTapEnabled
    self.wasDisabledByTimeout = wasDisabledByTimeout
    self.wasDisabledByUserInput = wasDisabledByUserInput
  }
}

@MainActor public final class KeyEventEngine {
  private var bindingSnapshot: BindingSnapshot
  private let appOpener: AppOpener
  private let logger: Logger
  private var verboseLogging: Bool
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var runLoop: CFRunLoop?
  private var wasDisabledByTimeout = false
  private var wasDisabledByUserInput = false

  public init(
    snapshot: BindingSnapshot = .empty,
    runtime: any AppRuntime,
    logger: Logger = KeybinddLoggers.engine,
    verboseLogging: Bool = false
  ) {
    self.bindingSnapshot = snapshot
    self.appOpener = AppOpener(
      runtime: runtime,
      logger: KeybinddLoggers.opener,
      verboseLogging: verboseLogging
    )
    self.logger = logger
    self.verboseLogging = verboseLogging
  }

  public var status: KeyEventEngineStatus {
    let installed = eventTap != nil
    let enabled = eventTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
    return KeyEventEngineStatus(
      isTapInstalled: installed,
      isTapEnabled: enabled,
      wasDisabledByTimeout: wasDisabledByTimeout,
      wasDisabledByUserInput: wasDisabledByUserInput
    )
  }

  public func start() throws {
    guard eventTap == nil else {
      return
    }

    let eventMask: CGEventMask = 1 << CGEventType.keyDown.rawValue
    let engine = Unmanaged.passUnretained(self).toOpaque()

    guard
      let tap = CGEvent.tapCreate(
        tap: .cghidEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: eventMask,
        callback: keyEventEngineTapCallback,
        userInfo: engine
      )
    else {
      throw KeyEventEngineError.eventTapInstallationFailed
    }

    let currentRunLoop = CFRunLoopGetCurrent()
    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
      CFMachPortInvalidate(tap)
      throw KeyEventEngineError.eventTapInstallationFailed
    }
    CFRunLoopAddSource(currentRunLoop, source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    eventTap = tap
    runLoopSource = source
    runLoop = currentRunLoop
    logger.info("event tap installed")
  }

  public func stop() {
    guard let tap = eventTap else {
      return
    }

    CGEvent.tapEnable(tap: tap, enable: false)
    if let runLoop, let runLoopSource {
      CFRunLoopRemoveSource(runLoop, runLoopSource, .commonModes)
    }
    CFMachPortInvalidate(tap)

    eventTap = nil
    runLoopSource = nil
    runLoop = nil
    logger.info("event tap stopped")
  }

  public func replaceSnapshot(
    _ snapshot: BindingSnapshot,
    verboseLogging: Bool
  ) {
    bindingSnapshot = snapshot
    self.verboseLogging = verboseLogging
    if verboseLogging {
      logger.debug("installed \(snapshot.count, privacy: .public) active binding(s)")
    }
  }

  func handleKeyEvent(
    _ type: CGEventType,
    _ event: CGEvent
  ) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if type == .tapDisabledByTimeout {
        wasDisabledByTimeout = true
      } else {
        wasDisabledByUserInput = true
      }

      if let tap = eventTap {
        CGEvent.tapEnable(tap: tap, enable: true)
        if verboseLogging {
          logger.debug("re-enabled event tap after system disable")
        }
      }
      return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown else {
      return Unmanaged.passUnretained(event)
    }

    let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags.intersection(KeyCode.relevantModifiersMask)

    if verboseLogging {
      logger.debug(
        "key event: keyCode=\(keyCode, privacy: .public) flags=\(flags.rawValue, privacy: .public)"
      )
    }

    if let binding = bindingSnapshot.match(keyCode: keyCode, modifiers: flags) {
      // Swallow autorepeat key-downs of a bound key so they never leak to the
      // foreground app, but only run the action once per physical press.
      guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
        return nil
      }

      logger.info(
        "matched: \(binding.description, privacy: .private) -> \(binding.identity.bundleIdentifier, privacy: .private)"
      )
      let appOpener = appOpener
      Task {
        await appOpener.open(binding)
      }
      return nil
    }

    return Unmanaged.passUnretained(event)
  }
}

private func keyEventEngineTapCallback(
  proxy _: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userInfo else {
    return Unmanaged.passUnretained(event)
  }

  let engine = Unmanaged<KeyEventEngine>.fromOpaque(userInfo).takeUnretainedValue()
  // The tap source is added to the main run loop in `start()`, so CoreGraphics
  // invokes this callback on the main thread. Keep the C callback nonisolated,
  // then assert the known confinement boundary before touching engine state.
  return MainActor.assumeIsolated {
    engine.handleKeyEvent(type, event)
  }
}
