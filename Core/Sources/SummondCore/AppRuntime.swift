import Foundation

public struct AppIdentity: Hashable, Sendable {
  public let bundleURL: URL
  public let bundleIdentifier: String

  public init(bundleURL: URL, bundleIdentifier: String) {
    self.bundleURL = bundleURL
    self.bundleIdentifier = bundleIdentifier
  }
}

public enum OpenAppResult: Sendable, Equatable {
  case launched
  case activatedExistingWindow
  case openedNewWindow
  case movedToCurrentSpace
  case failed(reason: String)
}

public protocol AppResolver: Sendable {
  func resolve(bundleID: String) -> AppIdentity?
}

public protocol AppRuntime: Sendable {
  func open(identity: AppIdentity, mode: AppOpenMode) async -> OpenAppResult
}

public struct RunningApplicationState: Sendable, Equatable {
  public let processID: pid_t
  public let isTerminated: Bool

  public init(processID: pid_t, isTerminated: Bool) {
    self.processID = processID
    self.isTerminated = isTerminated
  }
}
