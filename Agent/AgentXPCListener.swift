import Foundation
import OSLog
import SummondCore

final class AgentXPCListener: NSObject, NSXPCListenerDelegate {
  private let listener: NSXPCListener
  private let exportedObject: AgentXPCService
  private let logger: Logger

  init(supervisor: AgentSupervisor, logger: Logger = SummondLoggers.xpc) {
    self.listener = NSXPCListener(machServiceName: SummondBundleIdentifiers.agentMachService)
    self.exportedObject = AgentXPCService(supervisor: supervisor)
    self.logger = logger
    super.init()
    listener.delegate = self
  }

  func start() {
    listener.resume()
    logger.info("XPC listener resumed")
  }

  func listener(
    _: NSXPCListener,
    shouldAcceptNewConnection connection: NSXPCConnection
  ) -> Bool {
    if let teamIdentifier = CodeSigningIdentity.selfTeamIdentifier(logger: logger) {
      let requirement = XPCClientRequirement.clientRequirementString(teamIdentifier: teamIdentifier)
      connection.setCodeSigningRequirement(requirement)
    } else {
      #if DEBUG || SMOKE_TEST
        // Debug and smoke (ad-hoc, no team) builds accept any client; the smoke
        // build trades the team requirement for being runnable in a VM.
        logger.warning(
          "XPC client code-signing requirement skipped because this build has no team identifier")
      #else
        logger.fault(
          "XPC connection rejected because release agent could not derive its team identifier")
        return false
      #endif
    }

    connection.exportedInterface = NSXPCInterface(with: SummondAgentXPC.self)
    connection.exportedObject = exportedObject
    connection.resume()
    return true
  }
}

final class AgentXPCService: NSObject, SummondAgentXPC, @unchecked Sendable {
  private let supervisor: AgentSupervisor

  init(supervisor: AgentSupervisor) {
    self.supervisor = supervisor
  }

  func status(reply: @escaping (Data) -> Void) {
    let reply = XPCReply(reply)
    let supervisor = supervisor
    Task { @MainActor in
      reply.send(AgentStatusCodec.encode(supervisor.status()))
    }
  }

  func reloadConfiguration(reply: @escaping (Data) -> Void) {
    let reply = XPCReply(reply)
    let supervisor = supervisor
    Task { @MainActor in
      reply.send(AgentStatusCodec.encode(supervisor.reloadConfiguration()))
    }
  }

  func requestAccessibilityPrompt(reply: @escaping (Data) -> Void) {
    let reply = XPCReply(reply)
    let supervisor = supervisor
    Task { @MainActor in
      supervisor.requestAccessibilityPrompt()
      reply.send(Data())
    }
  }
}

private struct XPCReply: @unchecked Sendable {
  let send: (Data) -> Void

  init(_ send: @escaping (Data) -> Void) {
    self.send = send
  }
}
