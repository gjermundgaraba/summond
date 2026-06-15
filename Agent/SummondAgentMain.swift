import AppKit
import Foundation
import SummondCore
import OSLog

@main
struct SummondAgentMain {
  @MainActor
  static func main() {
    NSApplication.shared.setActivationPolicy(.accessory)

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
    guard listener.start() else {
      SummondLoggers.agent.fault("failed to start XPC listener")
      exit(1)
    }

    supervisor.bootstrap()
    RunLoop.main.run()
  }
}
