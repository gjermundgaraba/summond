@preconcurrency import CoreGraphics
import Foundation
import OSLog
import os

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

/// Installs a global `CGEvent` keyboard tap and dispatches matched shortcuts.
///
/// The tap runs on a **dedicated thread** with its own run loop, not the main
/// run loop. An active `.cghidEventTap` makes the window server route every
/// keystroke through this callback and wait for it to return before delivering
/// the event, so the callback must never be starved by other main-thread work.
/// Hosting it on its own thread keeps keystroke delivery independent of any
/// main-thread stall (XPC, AX queries, app activation). All state the callback
/// touches lives behind an `OSAllocatedUnfairLock`, and the callback only ever
/// holds the lock for the few nanoseconds it takes to copy out the snapshot.
public final class KeyEventEngine: @unchecked Sendable {
  private struct State {
    var snapshot: BindingSnapshot
    var verboseLogging: Bool
    var eventTap: CFMachPort?
    var isStarting = false
    var wasDisabledByTimeout = false
    var wasDisabledByUserInput = false
  }

  private let state: OSAllocatedUnfairLock<State>
  private let appOpener: AppOpener
  private let logger: Logger

  public init(
    snapshot: BindingSnapshot = .empty,
    runtime: any AppRuntime,
    logger: Logger = SummondLoggers.engine,
    verboseLogging: Bool = false
  ) {
    self.state = OSAllocatedUnfairLock(
      uncheckedState: State(snapshot: snapshot, verboseLogging: verboseLogging)
    )
    self.appOpener = AppOpener(
      runtime: runtime,
      logger: SummondLoggers.opener,
      verboseLogging: verboseLogging
    )
    self.logger = logger
  }

  public var status: KeyEventEngineStatus {
    // Copy the tap out under the lock, then ask the source of truth whether it
    // is actually enabled rather than trusting a cached flag that can drift if a
    // re-enable silently fails or the tap is disabled outside our callback. The
    // tap is never invalidated for the life of the process, so it is safe to use
    // outside the lock.
    let (tap, wasDisabledByTimeout, wasDisabledByUserInput) = state.withLockUnchecked {
      ($0.eventTap, $0.wasDisabledByTimeout, $0.wasDisabledByUserInput)
    }
    return KeyEventEngineStatus(
      isTapInstalled: tap != nil,
      isTapEnabled: tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false,
      wasDisabledByTimeout: wasDisabledByTimeout,
      wasDisabledByUserInput: wasDisabledByUserInput
    )
  }

  public func start() throws {
    // Single-flight: claim the "starting" slot atomically so a concurrent or
    // re-entrant start() cannot spawn a second tap thread. `eventTap` is set
    // later, on the spawned thread, so guarding on it alone would leave that
    // window open. The slot is released by the tap thread when it finishes
    // setup (see finishStartup), not here -- so even a retry after the readiness
    // timeout below, while the first thread is still in flight, is suppressed
    // rather than racing it into a duplicate tap.
    let shouldStart = state.withLockUnchecked { state -> Bool in
      guard state.eventTap == nil, !state.isStarting else {
        return false
      }
      state.isStarting = true
      return true
    }
    guard shouldStart else {
      return
    }

    // The tap is created and serviced entirely on its own thread; we block here
    // only until that thread reports whether creation succeeded, so callers keep
    // the existing synchronous "throws on failure" contract.
    let ready = DispatchSemaphore(value: 0)
    let thread = Thread { [weak self] in
      guard let self else {
        ready.signal()
        return
      }
      self.runTapThread(signalingReadyWith: ready)
    }
    thread.name = "net.garaba.summond.keytap"
    thread.qualityOfService = .userInteractive
    thread.start()

    if ready.wait(timeout: .now() + 5) == .timedOut {
      // The thread is still in flight; it keeps the single-flight slot until it
      // reports, so retries no-op until then instead of spawning a duplicate.
      logger.error("event tap thread did not report readiness in time")
    }

    guard state.withLockUnchecked({ $0.eventTap != nil }) else {
      throw KeyEventEngineError.eventTapInstallationFailed
    }
    logger.info("event tap installed on dedicated thread")
  }

  public func replaceSnapshot(
    _ snapshot: BindingSnapshot,
    verboseLogging: Bool
  ) {
    state.withLockUnchecked { state in
      state.snapshot = snapshot
      state.verboseLogging = verboseLogging
    }
    if verboseLogging {
      logger.debug("installed \(snapshot.count, privacy: .public) active binding(s)")
    }
  }

  /// Runs on the dedicated tap thread: creates the tap, wires it to this
  /// thread's run loop, then services it for the lifetime of the process. The
  /// faceless agent runs until launchd kills it, at which point the OS reclaims
  /// the tap, so there is no separate teardown path.
  private func runTapThread(signalingReadyWith ready: DispatchSemaphore) {
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
      finishStartup(installedTap: nil)
      ready.signal()
      return
    }

    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
      CFMachPortInvalidate(tap)
      finishStartup(installedTap: nil)
      ready.signal()
      return
    }

    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    finishStartup(installedTap: tap)

    // Let start() observe the installed tap, then service it until the process
    // exits.
    ready.signal()
    CFRunLoopRun()
  }

  /// Records the outcome of a tap-thread setup attempt and releases the
  /// single-flight slot. Called exactly once per `runTapThread` -- with the
  /// installed tap on success, or `nil` on failure -- so the slot is held for
  /// the whole in-flight window, including past a `start()` readiness timeout.
  private func finishStartup(installedTap tap: CFMachPort?) {
    state.withLockUnchecked { state in
      state.eventTap = tap
      state.isStarting = false
    }
  }

  func handleKeyEvent(
    _ type: CGEventType,
    _ event: CGEvent
  ) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      let tap: CFMachPort? = state.withLockUnchecked { state in
        if type == .tapDisabledByTimeout {
          state.wasDisabledByTimeout = true
        } else {
          state.wasDisabledByUserInput = true
        }
        return state.eventTap
      }

      if let tap {
        CGEvent.tapEnable(tap: tap, enable: true)
        if verboseLoggingEnabled {
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

    // Copy the snapshot reference out under the lock, then match and dispatch
    // without holding it. BindingSnapshot is a value type backed by a
    // copy-on-write dictionary, so this is an O(1) retain, not a deep copy.
    let (snapshot, verboseLogging) = state.withLockUnchecked { ($0.snapshot, $0.verboseLogging) }

    if verboseLogging {
      logger.debug(
        "key event: keyCode=\(keyCode, privacy: .private) flags=\(flags.rawValue, privacy: .private)"
      )
    }

    if let binding = snapshot.match(keyCode: keyCode, modifiers: flags) {
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

  private var verboseLoggingEnabled: Bool {
    state.withLockUnchecked { $0.verboseLogging }
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

  // Invoked on the engine's dedicated tap thread (see KeyEventEngine.start()),
  // so there is no actor isolation to assert; handleKeyEvent guards its own
  // state with a lock.
  let engine = Unmanaged<KeyEventEngine>.fromOpaque(userInfo).takeUnretainedValue()
  return engine.handleKeyEvent(type, event)
}
