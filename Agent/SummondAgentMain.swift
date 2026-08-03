import AppKit
import ApplicationServices
import Foundation
import OSLog
import SummondCore

@main
struct SummondAgentMain {
  // Upper bound on every synchronous Accessibility message the agent sends
  // (e.g. the Dock-menu traversal in DockMenuOpener). The system default is
  // undocumented and applies per message, so without this a degraded Dock could
  // stall the main actor — and the XPC listener with it — across a multi-call
  // AX traversal.
  private static let axMessagingTimeoutSeconds: Float = 1.5

  @MainActor
  static func main() {
    NSApplication.shared.setActivationPolicy(.accessory)

    // Bound AX messaging process-wide before any AX work begins. The system-wide
    // element seeds the timeout for every AXUIElement the process creates.
    _ = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), axMessagingTimeoutSeconds)

    // Crash-loop circuit breaker. launchd relaunches the agent on every
    // unsuccessful exit (KeepAlive); if it is crash-looping, re-installing an
    // active CGEvent tap each launch can wedge the keyboard. Record this launch;
    // the supervisor consults the throttle live, so a tripped breaker defers the
    // tap and then recovers on its own once the launch burst ages out.
    let throttle = RestartThrottle()
    // This is private operational state in the agent's own defaults domain, not
    // the shared preferences suite read by the app.
    let launchHistoryDefaults = UserDefaults.standard
    let launchHistoryKey = "agent.launchHistory.v1"
    let now = Date().timeIntervalSince1970
    let launchHistory = throttle.record(
      launchHistoryDefaults.array(forKey: launchHistoryKey) as? [Double] ?? [],
      now: now
    )
    launchHistoryDefaults.set(launchHistory, forKey: launchHistoryKey)
    // This must reach disk before a crashing agent can be relaunched.
    launchHistoryDefaults.synchronize()
    if !throttle.shouldInstallTap(launches: launchHistory, now: now) {
      SummondLoggers.agent.fault(
        """
        restart loop detected (\(throttle.launchCount(in: launchHistory, now: now), privacy: .public) \
        launches in \(Int(throttle.windowSeconds), privacy: .public)s); deferring event tap until it cools
        """
      )
    }

    guard let store = UserDefaultsConfigurationStore() else {
      SummondLoggers.agent.fault("failed to create configuration store")
      exit(1)
    }

    let verboseLogging = VerboseLoggingState()
    let runtime = MacOSAppRuntime(verboseLogging: verboseLogging)
    let supervisor = AgentSupervisor(
      store: store,
      appResolver: InstalledAppResolver(),
      engine: KeyEventEngine(runtime: runtime, verboseLogging: verboseLogging),
      restartThrottle: throttle,
      launchHistory: launchHistory
    )
    let listener = AgentXPCListener(supervisor: supervisor)
    listener.start()

    _ = supervisor.reloadConfiguration()
    RunLoop.main.run()
  }
}
