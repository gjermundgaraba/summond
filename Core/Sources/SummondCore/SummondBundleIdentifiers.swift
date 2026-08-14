import Foundation

public enum SummondBundleIdentifiers {
  private static let productionBase = "net.garaba.summond"
  private static let localBase = "net.garaba.summond.local"
  private static let isLocal = isLocal(bundleIdentifier: Bundle.main.bundleIdentifier)
  private static let base = isLocal ? localBase : productionBase

  public static let app = base
  public static let agent = "\(base).agent"
  public static let statusItem = "\(base).ui"

  /// Mach service the agent's XPC listener vends and clients dial.
  public static let agentMachService = "\(agent).xpc"

  /// LaunchAgent plist name `SMAppService.agent(plistName:)` registers, bundled
  /// at `Contents/Library/LaunchAgents/`.
  public static let agentPlistName = "\(agent).plist"

  public static let urlScheme = isLocal ? "summond-local" : "summond"
  public static let configurationDirectoryName = isLocal ? "Summond Local" : "Summond"

  static func isLocal(bundleIdentifier: String?) -> Bool {
    bundleIdentifier == localBase || bundleIdentifier?.hasPrefix("\(localBase).") == true
  }
}
