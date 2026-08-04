@preconcurrency import CoreGraphics
import Foundation
import OSLog
import os

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
    var eventTap: CFMachPort?
    var isStarting = false
    var startupWaiters: [CheckedContinuation<Void, Never>] = []
    var wasDisabledByTimeout = false
    var wasDisabledByUserInput = false
  }

  private let state: OSAllocatedUnfairLock<State>
  private let appOpener: AppOpener
  private let logger: Logger
  private let verboseLogging: VerboseLoggingState

  public init(
    snapshot: BindingSnapshot = .empty,
    runtime: any AppRuntime,
    logger: Logger = SummondLoggers.engine,
    verboseLogging: VerboseLoggingState
  ) {
    self.state = OSAllocatedUnfairLock(
      uncheckedState: State(snapshot: snapshot)
    )
    self.appOpener = AppOpener(
      runtime: runtime,
      logger: SummondLoggers.opener,
      verboseLogging: verboseLogging
    )
    self.logger = logger
    self.verboseLogging = verboseLogging
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

  public func start() async {
    // Single-flight: claim the "starting" slot atomically so a concurrent or
    // re-entrant start() cannot spawn a second tap thread. Every caller waits
    // for that shared attempt, so status never mistakes startup for failure.
    await withCheckedContinuation { continuation in
      var resumesImmediately = false
      let shouldStart = state.withLockUnchecked { state -> Bool in
        guard state.eventTap == nil else {
          resumesImmediately = true
          return false
        }
        state.startupWaiters.append(continuation)
        guard !state.isStarting else {
          return false
        }
        state.isStarting = true
        return true
      }

      if resumesImmediately {
        continuation.resume()
      } else if shouldStart {
        let thread = Thread { [weak self] in
          self?.runTapThread()
        }
        thread.name = "net.garaba.summond.keytap"
        thread.qualityOfService = .userInteractive
        thread.start()
      }
    }
  }

  public func replaceSnapshot(
    _ snapshot: BindingSnapshot,
    verboseLogging: Bool
  ) {
    state.withLockUnchecked { state in
      state.snapshot = snapshot
    }
    self.verboseLogging.setEnabled(verboseLogging)
    if verboseLogging {
      logger.debug("installed \(snapshot.count, privacy: .public) active binding(s)")
    }
  }

  /// Runs on the dedicated tap thread: creates the tap, wires it to this
  /// thread's run loop, then services it for the lifetime of the process. The
  /// faceless agent runs until launchd kills it, at which point the OS reclaims
  /// the tap, so there is no separate teardown path.
  private func runTapThread() {
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
      logger.warning("event tap installation failed")
      return
    }

    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
      CFMachPortInvalidate(tap)
      finishStartup(installedTap: nil)
      logger.warning("event tap run-loop source creation failed")
      return
    }

    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    finishStartup(installedTap: tap)
    logger.info("event tap installed on dedicated thread")
    CFRunLoopRun()
  }

  /// Records the outcome of a tap-thread setup attempt and releases the
  /// single-flight slot. Called exactly once per `runTapThread` -- with the
  /// installed tap on success, or `nil` on failure -- so the slot is held for
  /// the whole in-flight window.
  private func finishStartup(installedTap tap: CFMachPort?) {
    let waiters = state.withLockUnchecked { state in
      state.eventTap = tap
      state.isStarting = false
      let waiters = state.startupWaiters
      state.startupWaiters.removeAll(keepingCapacity: true)
      return waiters
    }
    for waiter in waiters {
      waiter.resume()
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
        if verboseLogging.isEnabled {
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
    let snapshot = state.withLockUnchecked { $0.snapshot }

    if verboseLogging.isEnabled {
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
        "matched: \(binding.binding.shortcut.description, privacy: .private) -> \(binding.identity.bundleIdentifier, privacy: .private)"
      )
      let appOpener = appOpener
      Task(priority: .userInitiated) {
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

  // Invoked on the engine's dedicated tap thread (see KeyEventEngine.start()),
  // so there is no actor isolation to assert; handleKeyEvent guards its own
  // state with a lock.
  let engine = Unmanaged<KeyEventEngine>.fromOpaque(userInfo).takeUnretainedValue()
  return engine.handleKeyEvent(type, event)
}
