import Foundation

public enum SummondBundleIdentifiers {
  public static let app = "net.garaba.summond"
  public static let agent = "net.garaba.summond.agent"
  public static let statusItem = "net.garaba.summond.ui"

  /// Mach service the agent's XPC listener vends and clients dial.
  public static let agentMachService = "net.garaba.summond.agent.xpc"

  /// LaunchAgent plist name `SMAppService.agent(plistName:)` registers, bundled
  /// at `Contents/Library/LaunchAgents/`.
  public static let agentPlistName = "\(agent).plist"
}
