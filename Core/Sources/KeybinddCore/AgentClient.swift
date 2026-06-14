import Foundation
import OSLog

public protocol AgentClientProtocol: Sendable {
  func status() async throws -> AgentStatus
  func reloadConfiguration() async throws -> AgentStatus
  func requestAccessibilityPrompt()
  func requestInputMonitoringPrompt()
}

public final class AgentClient: @unchecked Sendable, AgentClientProtocol {
  private static let machServiceName = "net.garaba.keybindd.agent.xpc"

  private let lock = NSLock()
  private let logger: Logger
  private var connection: NSXPCConnection?
  private var inFlightCalls: [UUID: InFlightCall] = [:]

  public init(logger: Logger = KeybinddLoggers.xpc) {
    self.logger = logger
  }

  public func status() async throws -> AgentStatus {
    try await call(operation: "Agent status") { remote, reply in
      remote.status(reply: reply)
    }
  }

  public func reloadConfiguration() async throws -> AgentStatus {
    try await call(operation: "Agent configuration reload") { remote, reply in
      remote.reloadConfiguration(reply: reply)
    }
  }

  public func requestAccessibilityPrompt() {
    let remote = makeRemoteProxy { [logger] error in
      logger.error(
        "Accessibility prompt request failed: \(error.localizedDescription, privacy: .public)")
    }
    remote.requestAccessibilityPrompt()
  }

  public func requestInputMonitoringPrompt() {
    let remote = makeRemoteProxy { [logger] error in
      logger.error(
        "Input Monitoring prompt request failed: \(error.localizedDescription, privacy: .public)")
    }
    remote.requestInputMonitoringPrompt()
  }

  private func call(
    operation: String,
    _ body: @escaping @Sendable (KeybinddAgentXPC, @escaping @Sendable (Data) -> Void) -> Void
  ) async throws -> AgentStatus {
    let callID = UUID()
    return try await XPCAsyncBridge.perform(
      operation: operation,
      onResume: { [weak self] in
        self?.unregisterInFlightCall(callID)
      },
      { [weak self] responder in
        guard let self else {
          responder.resume(throwing: XPCBridgeError.connectionInvalidated(operation: operation))
          return
        }

        registerInFlightCall(id: callID, operation: operation, responder: responder)
        let remote = makeRemoteProxy { error in
          responder.resume(throwing: error)
        }
        body(remote) { data in
          do {
            responder.resume(returning: try AgentStatusCodec.decode(data))
          } catch {
            responder.resume(throwing: error)
          }
        }
      }
    )
  }

  private func makeRemoteProxy(
    errorHandler: @escaping (Error) -> Void = { _ in }
  ) -> KeybinddAgentXPC {
    connectionProxy().remoteObjectProxyWithErrorHandler(errorHandler) as! KeybinddAgentXPC
  }

  private func connectionProxy() -> NSXPCConnection {
    lock.withLock {
      if let connection {
        return connection
      }

      let newConnection = NSXPCConnection(machServiceName: Self.machServiceName, options: [])
      newConnection.remoteObjectInterface = NSXPCInterface(with: KeybinddAgentXPC.self)
      newConnection.interruptionHandler = { [weak self] in
        self?.failInFlightCalls { operation in
          XPCBridgeError.connectionInterrupted(operation: operation)
        }
        self?.clearConnection()
      }
      newConnection.invalidationHandler = { [weak self] in
        self?.failInFlightCalls { operation in
          XPCBridgeError.connectionInvalidated(operation: operation)
        }
        self?.clearConnection()
      }
      if let teamIdentifier = CodeSigningIdentity.selfTeamIdentifier(logger: logger) {
        let requirement = XPCClientRequirement.requirementString(
          teamIdentifier: teamIdentifier,
          bundleIdentifier: KeybinddBundleIdentifiers.agent
        )
        newConnection.setCodeSigningRequirement(requirement)
      } else {
        logger.warning(
          "XPC agent code-signing requirement skipped because client has no team identifier")
      }
      newConnection.resume()
      connection = newConnection
      return newConnection
    }
  }

  private func clearConnection() {
    lock.withLock {
      connection = nil
    }
  }

  private func registerInFlightCall(
    id: UUID,
    operation: String,
    responder: XPCOneShotResponder<AgentStatus>
  ) {
    lock.withLock {
      inFlightCalls[id] = InFlightCall(
        operation: operation,
        resumeThrowing: { error in
          responder.resume(throwing: error)
        }
      )
    }
  }

  private func unregisterInFlightCall(_ id: UUID) {
    lock.withLock {
      inFlightCalls[id] = nil
    }
  }

  private func failInFlightCalls(_ makeError: (String) -> any Error) {
    let calls = lock.withLock {
      let calls = Array(inFlightCalls.values)
      inFlightCalls.removeAll()
      return calls
    }

    for call in calls {
      call.resumeThrowing(makeError(call.operation))
    }
  }
}

private struct InFlightCall: Sendable {
  var operation: String
  var resumeThrowing: @Sendable (any Error) -> Void
}
