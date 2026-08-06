import Carbon.HIToolbox
import CoreGraphics
import Foundation
import OSLog

public struct HotKeyEngineStatus: Equatable, Sendable {
  public let isHandlerInstalled: Bool
  public let failedShortcuts: [String]

  public init(isHandlerInstalled: Bool, failedShortcuts: [String]) {
    self.isHandlerInstalled = isHandlerInstalled
    self.failedShortcuts = failedShortcuts
  }
}

/// The system hot-key registry the engine drives. Split from the engine so
/// tests can observe registrations without touching the real Carbon registry.
@MainActor
public protocol HotKeySystem: AnyObject {
  /// Installs the process-wide hot-key event handler. `dispatch` is invoked
  /// with the registered hot-key ID each time a bound shortcut is pressed.
  func installHandler(dispatch: @escaping @MainActor (UInt32) -> Void) -> Bool
  func register(keyCode: UInt32, carbonModifiers: UInt32, hotKeyID: UInt32) -> OSStatus
  func unregisterAll()
}

/// Registers configured shortcuts as system hot keys and dispatches matches.
///
/// Hot keys are matched inside the window server and delivered on the main run
/// loop, so unlike a `CGEvent` tap this needs no dedicated thread, no
/// Accessibility or Input Monitoring permission, and keeps working while
/// another process holds secure keyboard entry. A registered combo is consumed
/// system-wide, matching the old tap's swallow-on-match behavior.
///
/// Registration only happens while the handler is installed: a hot key with no
/// handler would still consume its keystroke system-wide but silently drop it,
/// so `replaceSnapshot` before `start()` just stores the snapshot.
@MainActor
public final class HotKeyEngine {
  private let system: any HotKeySystem
  private let appOpener: AppOpener
  private let logger: Logger
  private let verboseLogging: VerboseLoggingState
  private var snapshot: BindingSnapshot
  private var bindingsByHotKeyID: [UInt32: CompiledAppBinding] = [:]
  private var failedShortcuts: [String] = []
  private var isHandlerInstalled = false
  private var nextHotKeyID: UInt32 = 0

  public init(
    snapshot: BindingSnapshot = .empty,
    runtime: any AppRuntime,
    system: (any HotKeySystem)? = nil,
    logger: Logger = SummondLoggers.engine,
    verboseLogging: VerboseLoggingState
  ) {
    self.snapshot = snapshot
    self.system = system ?? CarbonHotKeySystem()
    self.appOpener = AppOpener(
      runtime: runtime,
      logger: SummondLoggers.opener,
      verboseLogging: verboseLogging
    )
    self.logger = logger
    self.verboseLogging = verboseLogging
  }

  public var status: HotKeyEngineStatus {
    HotKeyEngineStatus(
      isHandlerInstalled: isHandlerInstalled,
      failedShortcuts: failedShortcuts
    )
  }

  public func start() {
    guard !isHandlerInstalled else {
      return
    }
    isHandlerInstalled = system.installHandler { [weak self] hotKeyID in
      self?.dispatch(hotKeyID: hotKeyID)
    }
    guard isHandlerInstalled else {
      logger.warning("hot-key event handler installation failed")
      return
    }
    logger.info("hot-key event handler installed")
    applyRegistrations()
  }

  public func replaceSnapshot(
    _ snapshot: BindingSnapshot,
    verboseLogging: Bool
  ) {
    self.snapshot = snapshot
    self.verboseLogging.setEnabled(verboseLogging)
    if verboseLogging {
      logger.debug("installed \(snapshot.count, privacy: .public) active binding(s)")
    }
    applyRegistrations()
  }

  private func applyRegistrations() {
    guard isHandlerInstalled else {
      return
    }
    system.unregisterAll()
    bindingsByHotKeyID.removeAll()
    failedShortcuts.removeAll()

    for (shortcut, binding) in snapshot.bindingsByTrigger {
      nextHotKeyID += 1
      let status = system.register(
        keyCode: UInt32(shortcut.keyCode),
        carbonModifiers: KeyCode.carbonModifiers(for: shortcut.modifiers),
        hotKeyID: nextHotKeyID
      )
      if status == noErr {
        bindingsByHotKeyID[nextHotKeyID] = binding
      } else {
        failedShortcuts.append(binding.binding.shortcut.description)
        logger.warning(
          "hot-key registration failed (\(status, privacy: .public)): \(binding.binding.shortcut.description, privacy: .private)"
        )
      }
    }
    // Snapshot iteration order is dictionary order; sort so status and UI are
    // deterministic across reloads.
    failedShortcuts.sort()
  }

  private func dispatch(hotKeyID: UInt32) {
    guard let binding = bindingsByHotKeyID[hotKeyID] else {
      return
    }
    if verboseLogging.isEnabled {
      logger.debug("hot key fired: id=\(hotKeyID, privacy: .public)")
    }
    logger.info(
      "matched: \(binding.binding.shortcut.description, privacy: .private) -> \(binding.identity.bundleIdentifier, privacy: .private)"
    )
    let appOpener = appOpener
    Task(priority: .userInitiated) {
      await appOpener.open(binding)
    }
  }
}

extension KeyCode {
  public static func carbonModifiers(for flags: CGEventFlags) -> UInt32 {
    var modifiers: UInt32 = 0
    if flags.contains(.maskCommand) { modifiers |= UInt32(cmdKey) }
    if flags.contains(.maskShift) { modifiers |= UInt32(shiftKey) }
    if flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey) }
    if flags.contains(.maskControl) { modifiers |= UInt32(controlKey) }
    return modifiers
  }
}

@MainActor
final class CarbonHotKeySystem: HotKeySystem {
  // FourCC "SMND"; identifies this process's hot keys in EventHotKeyID.
  private static let signature: OSType = 0x534D_4E44

  private var hotKeyRefs: [EventHotKeyRef] = []
  private var handlerRef: EventHandlerRef?
  fileprivate var dispatch: (@MainActor (UInt32) -> Void)?

  func installHandler(dispatch: @escaping @MainActor (UInt32) -> Void) -> Bool {
    self.dispatch = dispatch
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    let status = InstallEventHandler(
      GetEventDispatcherTarget(),
      carbonHotKeyEventHandler,
      1,
      &eventType,
      Unmanaged.passUnretained(self).toOpaque(),
      &handlerRef
    )
    return status == noErr
  }

  func register(keyCode: UInt32, carbonModifiers: UInt32, hotKeyID: UInt32) -> OSStatus {
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      keyCode,
      carbonModifiers,
      EventHotKeyID(signature: Self.signature, id: hotKeyID),
      GetEventDispatcherTarget(),
      0,
      &ref
    )
    if status == noErr, let ref {
      hotKeyRefs.append(ref)
    }
    return status
  }

  func unregisterAll() {
    for ref in hotKeyRefs {
      UnregisterEventHotKey(ref)
    }
    hotKeyRefs.removeAll()
  }
}

/// Carbon delivers hot-key events on the main thread's event dispatcher, so
/// entering the main actor is an assertion, not a hop.
private func carbonHotKeyEventHandler(
  _: EventHandlerCallRef?,
  event: EventRef?,
  userData: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let event, let userData else {
    return OSStatus(eventNotHandledErr)
  }

  var hotKeyID = EventHotKeyID()
  let status = GetEventParameter(
    event,
    EventParamName(kEventParamDirectObject),
    EventParamType(typeEventHotKeyID),
    nil,
    MemoryLayout<EventHotKeyID>.size,
    nil,
    &hotKeyID
  )
  guard status == noErr else {
    return status
  }

  let system = Unmanaged<CarbonHotKeySystem>.fromOpaque(userData).takeUnretainedValue()
  MainActor.assumeIsolated {
    system.dispatch?(hotKeyID.id)
  }
  return noErr
}
