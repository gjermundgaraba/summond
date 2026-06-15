import AppKit
import Foundation
import SummondCore
import OSLog

@main
struct SummondAgentMain {
  @MainActor
  static func main() {
    NSApplication.shared.setActivationPolicy(.accessory)

    guard let store = UserDefaultsConfigurationStore() else {
      SummondLoggers.agent.fault("failed to create configuration store")
      exit(1)
    }

    let supervisor = AgentSupervisor(
      store: store,
      appResolver: InstalledAppResolver(),
      engine: KeyEventEngine(runtime: MacOSAppRuntime())
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
