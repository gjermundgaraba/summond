import Foundation
import OSLog

public protocol AgentClientProtocol: Sendable {
  func status() async throws -> AgentStatus
  func reloadConfiguration() async throws -> AgentStatus
  func requestAccessibilityPrompt() async throws
  func requestInputMonitoringPrompt() async throws
}

private struct MissingTeamIdentifierError: LocalizedError {
  let errorDescription: String? =
    "The XPC peer could not be authenticated because this build has no Team ID."
}

public final class AgentClient: @unchecked Sendable, AgentClientProtocol {
  private let makeConnection: @Sendable () throws -> NSXPCConnection

  public convenience init(logger: Logger = SummondLoggers.xpc) {
    self.init {
      try Self.makeMachServiceConnection(logger: logger)
    }
  }

  init(makeConnection: @escaping @Sendable () throws -> NSXPCConnection) {
    self.makeConnection = makeConnection
  }

  private static func makeMachServiceConnection(logger: Logger) throws -> NSXPCConnection {
    let connection = NSXPCConnection(
      machServiceName: SummondBundleIdentifiers.agentMachService, options: [])
    if let teamIdentifier = CodeSigningIdentity.selfTeamIdentifier(logger: logger) {
      connection.setCodeSigningRequirement(
        XPCClientRequirement.requirementString(
          teamIdentifier: teamIdentifier,
          bundleIdentifier: SummondBundleIdentifiers.agent
        ))
    } else {
      #if DEBUG || SMOKE_TEST
        logger.warning(
          "XPC agent code-signing requirement skipped because this debug or smoke build has no team identifier"
        )
      #else
        throw MissingTeamIdentifierError()
      #endif
    }
    return connection
  }

  public func status() async throws -> AgentStatus {
    try AgentStatusCodec.decode(
      await call(operation: "Agent status") { remote, reply in
        remote.status(reply: reply)
      })
  }

  public func reloadConfiguration() async throws -> AgentStatus {
    try AgentStatusCodec.decode(
      await call(operation: "Agent configuration reload") { remote, reply in
        remote.reloadConfiguration(reply: reply)
      })
  }

  public func requestAccessibilityPrompt() async throws {
    _ = try await call(operation: "Accessibility prompt request") { remote, reply in
      remote.requestAccessibilityPrompt(reply: reply)
    }
  }

  public func requestInputMonitoringPrompt() async throws {
    _ = try await call(operation: "Input Monitoring prompt request") { remote, reply in
      remote.requestInputMonitoringPrompt(reply: reply)
    }
  }

  private func call(
    operation: String,
    _ body: @escaping @Sendable (SummondAgentXPC, @escaping @Sendable (Data) -> Void) -> Void
  ) async throws -> Data {
    let connection = XPCConnectionBox(value: try makeConnection())
    connection.value.remoteObjectInterface = NSXPCInterface(with: SummondAgentXPC.self)
    defer { connection.value.invalidate() }

    return try await XPCAsyncBridge.perform(
      operation: operation,
      { responder in
        connection.value.interruptionHandler = {
          responder.resume(
            throwing: XPCBridgeError.connectionInterrupted(operation: operation))
        }
        connection.value.invalidationHandler = {
          responder.resume(
            throwing: XPCBridgeError.connectionInvalidated(operation: operation))
        }
        connection.value.resume()

        let remote =
          connection.value.remoteObjectProxyWithErrorHandler { error in
            responder.resume(throwing: error)
          } as! SummondAgentXPC
        body(remote) { data in
          responder.resume(returning: data)
        }
      }
    )
  }
}

private struct XPCConnectionBox: @unchecked Sendable {
  let value: NSXPCConnection
}
