import AppKit
import CoreGraphics
import Foundation

final class Daemon {
  private let configPath: String
  private let appResolver: any AppResolver
  private var bindingSnapshot: BindingSnapshot
  private let appOpener: AppOpener
  private let logger: Logger
  private var eventTap: CFMachPort?
  private var signalSources: [DispatchSourceSignal] = []

  init(
    configPath: String,
    appResolver: any AppResolver = InstalledAppResolver(),
    runtime: any AppRuntime,
    logger: Logger = Logger()
  ) {
    self.configPath = configPath
    self.appResolver = appResolver
    self.logger = logger
    self.appOpener = AppOpener(runtime: runtime, logger: logger)
    self.bindingSnapshot = .empty
  }

  func start() {
    guard PidFile.acquire(logger: logger) else {
      Foundation.exit(1)
    }

    // Register as a (headless) GUI application. WindowServer only honors the
    // private space-move operation behind `move` mode for processes with a
    // registered application connection; `.accessory` keeps the daemon out of
    // the Dock and menu bar. The run loop is still driven by `CFRunLoopRun()`.
    // `start()` is the main-thread entry point, so the main-actor work is safe.
    MainActor.assumeIsolated {
      _ = NSApplication.shared.setActivationPolicy(.accessory)
    }

    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: configPath),
      !BindingConfigStore.ensureExists(at: configPath, logger: logger)
    {
      logger.error("failed to create config at '\(configPath)'")
      cleanup()
      Foundation.exit(1)
    }

    do {
      let result = try BindingConfigStore.load(from: configPath, appResolver: appResolver)
      bindingSnapshot = result.snapshot
      logger.info("loaded \(result.snapshot.count) binding(s) from config")
    } catch {
      logger.error("failed to load config: \(error.localizedDescription)")
      cleanup()
      Foundation.exit(1)
    }

    installSignalHandlers()

    guard installEventTap() else {
      logger.error(
        "failed to create event tap. Grant accessibility permissions in System Settings > Privacy & Security > Accessibility"
      )
      cleanup()
      Foundation.exit(1)
    }

    logger.info("daemon started")
    logger.info("config: \(configPath)")
    CFRunLoopRun()
  }

  func shutdown() {
    logger.info("shutting down")
    cleanup()
    Foundation.exit(0)
  }

  private func installEventTap() -> Bool {
    let eventMask: CGEventMask = 1 << CGEventType.keyDown.rawValue
    let daemon = Unmanaged.passUnretained(self).toOpaque()

    guard
      let tap = CGEvent.tapCreate(
        tap: .cghidEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: eventMask,
        callback: eventTapCallback,
        userInfo: daemon
      )
    else {
      return false
    }

    eventTap = tap
    let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
  }

  fileprivate func handleKeyEvent(_ _: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent)
    -> Unmanaged<CGEvent>?
  {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap = eventTap {
        CGEvent.tapEnable(tap: tap, enable: true)
        logger.debug("re-enabled event tap")
      }
      return Unmanaged.passRetained(event)
    }

    guard type == .keyDown else {
      return Unmanaged.passRetained(event)
    }

    let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags.intersection(KeyCode.relevantModifiersMask)
    let appOpener = self.appOpener

    logger.debug("key event: keyCode=\(keyCode) flags=\(flags.rawValue)")

    if let binding = bindingSnapshot.match(keyCode: keyCode, modifiers: flags) {
      logger.info("matched: \(binding.description) -> \(binding.identity.bundleIdentifier)")
      Task {
        await appOpener.open(binding)
      }
      return nil
    }

    return Unmanaged.passRetained(event)
  }

  private func installSignalHandlers() {
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)

    let signalQueue = DispatchQueue(label: "gg.keybindd.signals")

    let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
    termSource.setEventHandler { [weak self] in
      performOnMainRunLoop {
        self?.shutdown()
      }
    }
    termSource.resume()

    let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
    intSource.setEventHandler { [weak self] in
      performOnMainRunLoop {
        self?.shutdown()
      }
    }
    intSource.resume()

    signalSources = [termSource, intSource]
  }

  private func cleanup() {
    if let tap = eventTap {
      CGEvent.tapEnable(tap: tap, enable: false)
      eventTap = nil
    }

    signalSources.removeAll()
    PidFile.remove()
  }
}

private func eventTapCallback(
  proxy: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userInfo else {
    return Unmanaged.passRetained(event)
  }

  let daemon = Unmanaged<Daemon>.fromOpaque(userInfo).takeUnretainedValue()
  return daemon.handleKeyEvent(proxy, type, event)
}

private func performOnMainRunLoop(_ body: @escaping () -> Void) {
  CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
    body()
  }
  CFRunLoopWakeUp(CFRunLoopGetMain())
}
