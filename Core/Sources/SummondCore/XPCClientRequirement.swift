import Foundation

public enum XPCClientRequirement {
  /// Bundle identifiers allowed to connect to the agent's XPC service: the
  /// main app and the menu bar status item.
  public static let allowedClientBundleIdentifiers = [
    SummondBundleIdentifiers.app,
    SummondBundleIdentifiers.statusItem,
  ]

  /// Requirement the agent's listener applies to incoming clients.
  ///
  /// Each allowed client is pinned by exact bundle identifier. A `*` inside a
  /// quoted string in the code-signing requirement language is a *literal*
  /// asterisk, not a wildcard — `info[CFBundleIdentifier] = "net.garaba.summond*"`
  /// never matches anything, so do not build prefix requirements that way.
  public static func clientRequirementString(
    teamIdentifier: String,
    bundleIdentifiers: [String] = allowedClientBundleIdentifiers
  ) -> String {
    let escapedTeam = escapeRequirementString(teamIdentifier)
    let identifierClause =
      bundleIdentifiers
      .map { "info[CFBundleIdentifier] = \"\(escapeRequirementString($0))\"" }
      .joined(separator: " or ")
    return """
      anchor apple generic and certificate leaf[subject.OU] = "\(escapedTeam)" and (\(identifierClause))
      """
  }

  /// Requirement the app and status item apply to the agent they connect to.
  public static func requirementString(
    teamIdentifier: String,
    bundleIdentifier: String
  ) -> String {
    let escapedTeamIdentifier = escapeRequirementString(teamIdentifier)
    let escapedBundleIdentifier = escapeRequirementString(bundleIdentifier)
    return """
      anchor apple generic and certificate leaf[subject.OU] = "\(escapedTeamIdentifier)" and info[CFBundleIdentifier] = "\(escapedBundleIdentifier)"
      """
  }

  private static func escapeRequirementString(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }
}
