import Foundation

struct AppIdentity: Hashable, Sendable {
  let bundleURL: URL
  let bundleIdentifier: String
}

enum OpenAppResult: Sendable, Equatable {
  case launched(bundleIdentifier: String)
  case activatedExistingWindow(bundleIdentifier: String)
  case openedNewWindow(bundleIdentifier: String)
  case failed(bundleIdentifier: String, reason: String)
}

protocol AppResolver: Sendable {
  func resolve(bundleID: String) -> AppIdentity?
}

protocol AppRuntime: Sendable {
  func open(identity: AppIdentity, mode: AppOpenMode) async -> OpenAppResult
}

struct RunningApplicationState: Sendable, Equatable {
  let bundleIdentifier: String
  let processID: pid_t
  let isTerminated: Bool
}
