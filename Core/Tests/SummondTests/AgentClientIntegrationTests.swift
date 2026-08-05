import Foundation
import Testing

@testable import SummondCore

/// Exercises the real AgentClient machinery — NSXPC connection setup, the
/// XPCAsyncBridge one-shot reply path, AgentStatusCodec decode, and the
/// interruption/invalidation handling — across a genuine XPC boundary, by
/// connecting to an in-process anonymous NSXPCListener instead of the agent's
/// mach service. No signing, launchd, SMAppService, or VM is involved here; the
/// launchd + mach-service path is exercised by the Tart smoke (`make smoke-tart`).
@Suite("AgentClient XPC integration")
struct AgentClientIntegrationTests {
  private static let statusA = AgentStatus(
    agentVersion: "A",
    accessibilityGranted: true,
    shortcutsActive: true,
    configState: .ok,
    bindingCount: 1,
    lastReloadError: nil
  )
  private static let statusB = AgentStatus(
    agentVersion: "B",
    accessibilityGranted: false,
    shortcutsActive: false,
    configState: .fresh,
    bindingCount: 0,
    lastReloadError: nil
  )

  private func makeHarness(statusPayload: Data? = nil) -> AnonymousAgentHarness {
    AnonymousAgentHarness(
      stub: StubAgentXPCService(
        statusPayload: statusPayload ?? AgentStatusCodec.encode(Self.statusA),
        reloadPayload: AgentStatusCodec.encode(Self.statusB)
      )
    )
  }

  @Test("A malformed reply surfaces a decode error")
  func malformedReplyDecodeError() async throws {
    let harness = makeHarness(statusPayload: Data("not-json".utf8))
    defer { withExtendedLifetime(harness) {} }

    let client = harness.makeClient()
    await #expect(throws: DecodingError.self) {
      _ = try await client.status()
    }
  }

  @Test("Connection teardown fails an in-flight call without waiting for the timeout")
  func inFlightTeardownFails() async throws {
    let harness = makeHarness()
    harness.stub.setHold(true)
    defer { withExtendedLifetime(harness) {} }

    let client = harness.makeClient()
    let task = Task { try await client.status() }
    await harness.stub.waitForStatusCall()
    harness.invalidateAcceptedConnections()

    switch await task.result {
    case .success:
      Issue.record("Expected the in-flight call to fail when the connection tore down")
    case .failure(let error):
      // The race between the bridge resuming and the invalidation handler firing
      // is non-deterministic, so accept any failure that is not the bridge
      // timeout (the deterministic error mapping is covered by XPCAsyncBridgeTests).
      if let bridgeError = error as? XPCBridgeError, case .timedOut = bridgeError {
        Issue.record("In-flight call hit the bridge timeout instead of failing on teardown")
      }
    }
  }

  @Test("Cancellation invalidates an in-flight connection")
  func cancellationInvalidatesConnection() async {
    let harness = makeHarness()
    harness.stub.setHold(true)
    defer { withExtendedLifetime(harness) {} }

    let task = Task { try await harness.makeClient().status() }
    await harness.stub.waitForStatusCall()
    task.cancel()

    switch await task.result {
    case .success:
      Issue.record("Expected the cancelled call to fail")
    case .failure(let error):
      #expect(error as? XPCBridgeError == .cancelled(operation: "Agent status"))
    }
    #expect(await harness.waitForInvalidatedConnection())
  }

  @Test("Sequential calls round-trip across fresh connections")
  func roundTripsAcrossOneShotConnections() async throws {
    let harness = makeHarness()
    defer { withExtendedLifetime(harness) {} }

    let client = harness.makeClient()
    #expect(try await client.status() == Self.statusA)
    #expect(try await client.reloadConfiguration() == Self.statusB)
    #expect(harness.acceptedConnectionCount() == 2)
  }

  @Test("Permission prompt calls wait for acknowledgement")
  func permissionPromptsAreAcknowledged() async throws {
    let harness = makeHarness()
    defer { withExtendedLifetime(harness) {} }

    let client = harness.makeClient()
    try await client.requestAccessibilityPrompt()

    #expect(harness.stub.accessibilityPromptCount() == 1)
    #expect(harness.acceptedConnectionCount() == 1)
  }
}

/// In-process stub agent that replies with canned encoded `AgentStatus` data,
/// can hold a `status` reply open to model an in-flight call, and signals when
/// a `status` call has arrived.
private final class StubAgentXPCService: NSObject, SummondAgentXPC, @unchecked Sendable {
  private let lock = NSLock()
  private let statusPayload: Data
  private let reloadPayload: Data
  private var hold = false
  private var heldReplies: [(Data) -> Void] = []
  private var statusCallArrived = false
  private var statusCallArrival: CheckedContinuation<Void, Never>?
  private var storedAccessibilityPromptCount = 0

  init(statusPayload: Data, reloadPayload: Data) {
    self.statusPayload = statusPayload
    self.reloadPayload = reloadPayload
  }

  func setHold(_ value: Bool) {
    lock.withLock { hold = value }
  }

  func status(reply: @escaping (Data) -> Void) {
    let (shouldHold, payload, arrival): (Bool, Data, CheckedContinuation<Void, Never>?) =
      lock.withLock {
        let arrival = statusCallArrival
        statusCallArrival = nil
        statusCallArrived = true
        return (hold, statusPayload, arrival)
      }
    arrival?.resume()
    if shouldHold {
      lock.withLock { heldReplies.append(reply) }
    } else {
      reply(payload)
    }
  }

  func reloadConfiguration(reply: @escaping (Data) -> Void) {
    reply(reloadPayload)
  }

  func requestAccessibilityPrompt(reply: @escaping (Data) -> Void) {
    lock.withLock { storedAccessibilityPromptCount += 1 }
    reply(Data())
  }

  func accessibilityPromptCount() -> Int {
    lock.withLock { storedAccessibilityPromptCount }
  }

  /// Suspends until `status` has been invoked at least once, resolving the
  /// register-vs-arrive race in either order.
  func waitForStatusCall() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let resumeNow = lock.withLock { () -> Bool in
        if statusCallArrived {
          return true
        }
        statusCallArrival = continuation
        return false
      }
      if resumeNow {
        continuation.resume()
      }
    }
  }
}

/// Hosts an anonymous NSXPCListener exporting `stub`, and hands out AgentClients
/// wired to its endpoint (no code-signing requirement, since the peer is the
/// same in-process test).
private final class AnonymousAgentHarness: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
  let listener = NSXPCListener.anonymous()
  let stub: StubAgentXPCService
  private let lock = NSLock()
  private var acceptedConnections: [NSXPCConnection] = []
  private var invalidatedConnectionCount = 0

  init(stub: StubAgentXPCService) {
    self.stub = stub
    super.init()
    listener.delegate = self
    listener.resume()
  }

  func listener(
    _: NSXPCListener,
    shouldAcceptNewConnection connection: NSXPCConnection
  ) -> Bool {
    connection.exportedInterface = NSXPCInterface(with: SummondAgentXPC.self)
    connection.exportedObject = stub
    connection.invalidationHandler = { [weak self] in
      self?.lock.withLock {
        self?.invalidatedConnectionCount += 1
      }
    }
    lock.withLock { acceptedConnections.append(connection) }
    connection.resume()
    return true
  }

  func acceptedConnectionCount() -> Int {
    lock.withLock { acceptedConnections.count }
  }

  func invalidateAcceptedConnections() {
    for connection in lock.withLock({ acceptedConnections }) {
      connection.invalidate()
    }
  }

  func waitForInvalidatedConnection() async -> Bool {
    for _ in 0..<100 {
      if lock.withLock({ invalidatedConnectionCount > 0 }) {
        return true
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }

  func makeClient() -> AgentClient {
    let endpoint = listener.endpoint
    return AgentClient(
      makeConnection: { NSXPCConnection(listenerEndpoint: endpoint) }
    )
  }
}
