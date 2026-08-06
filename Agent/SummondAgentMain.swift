import AppKit
import ApplicationServices
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

    let verboseLogging = VerboseLoggingState()
    let runtime = MacOSAppRuntime(verboseLogging: verboseLogging)
    let supervisor = AgentSupervisor(
      store: FileConfigurationStore(),
      appResolver: InstalledAppResolver(),
      engine: HotKeyEngine(runtime: runtime, verboseLogging: verboseLogging)
    )
    supervisor.start()
    let listener = AgentXPCListener(supervisor: supervisor)
    listener.start()
    // NSApplication.run (not RunLoop.run) so the Carbon event dispatcher that
    // delivers registered hot keys is serviced.
    NSApplication.shared.run()
  }
}
