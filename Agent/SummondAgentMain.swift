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
    let launchHistoryStore = LaunchHistoryStore()
    let now = Date().timeIntervalSince1970
    let launchHistory = throttle.record(launchHistoryStore.load(), now: now)
    launchHistoryStore.save(launchHistory)
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

    let supervisor = AgentSupervisor(
      store: store,
      appResolver: InstalledAppResolver(),
      engine: KeyEventEngine(runtime: MacOSAppRuntime()),
      restartThrottle: throttle,
      launchHistory: launchHistory
    )
    let listener = AgentXPCListener(supervisor: supervisor)
    listener.start()

    supervisor.bootstrap()
    RunLoop.main.run()
  }
}
