import Foundation

enum PermissionFlowHelperAppLocator {
  static func bundledAgentAppURL() -> URL? {
    let agentAppURL = Bundle.main.bundleURL
      .appendingPathComponent("Contents/MacOS/SummondAgent.app", isDirectory: true)
      .standardizedFileURL
    guard FileManager.default.fileExists(atPath: agentAppURL.path) else {
      return nil
    }
    return agentAppURL
  }
}
