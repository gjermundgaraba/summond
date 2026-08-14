import Foundation

enum PermissionFlowHelperAppLocator {
  static func bundledAgentAppURL() -> URL? {
    guard
      let bundlePath = Bundle.main.object(forInfoDictionaryKey: "SummondAgentBundlePath")
        as? String
    else {
      return nil
    }
    let agentAppURL = Bundle.main.bundleURL
      .appendingPathComponent(bundlePath, isDirectory: true)
      .standardizedFileURL
    guard FileManager.default.fileExists(atPath: agentAppURL.path) else {
      return nil
    }
    return agentAppURL
  }
}
