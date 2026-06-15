import Foundation
import KeybinddCore
import Testing

@testable import Keybindd

@MainActor
@Suite("Service manager")
struct ServiceManagerTests {
  @Test("Drops concurrent show-menu-bar toggles instead of racing them")
  func dropsConcurrentStatusItemToggles() async throws {
    let statusItem = SuspendingLoginItemService()
    let manager = ServiceManager(
      agentService: StubLoginItemService(),
      statusItemService: statusItem,
      agentClient: StubAgentClient()
    )

    // Start a toggle that suspends inside register(), holding the busy flag.
    let firstToggle = Task { await manager.setStatusItemShown(true) }
    let suspended = await statusItem.waitUntilRegisterSuspended()
    #expect(suspended)
    guard suspended else {
      firstToggle.cancel()
      return
    }
    #expect(manager.isStatusItemBusy)

    // A second toggle while the first is in flight must be dropped, because the
    // real Settings toggle is disabled until the current SMAppService call ends.
    await manager.setStatusItemShown(false)
    #expect(statusItem.registerCalls == 1)
    #expect(statusItem.unregisterCalls == 0)

    try #require(statusItem.resumeRegister())
    await firstToggle.value
    #expect(!manager.isStatusItemBusy)
    #expect(statusItem.registerCalls == 1)
    #expect(statusItem.unregisterCalls == 0)
  }

  @Test("Restarts enabled service when the agent is unreachable")
  func restartsUnreachableService() async {
    let agentService = CountingLoginItemService(status: .enabled)
    let manager = ServiceManager(
      agentService: agentService,
      statusItemService: StubLoginItemService(),
      agentClient: ThrowingAgentClient()
    )

    await manager.refresh()
    #expect(manager.setupState.firstUnmetOnboardingStep == .backgroundService)

    await manager.restartServiceRegistration()

    #expect(agentService.unregisterCalls == 1)
    #expect(agentService.registerCalls == 1)
    #expect(manager.setupState.firstUnmetOnboardingStep == .backgroundService)
  }
}

private final class SuspendingLoginItemService: LoginItemServiceManaging, @unchecked Sendable {
  private let lock = NSLock()
  private var registerCount = 0
  private var unregisterCount = 0
  private var pending: CheckedContinuation<Void, Never>?

  var status: ServiceRegistrationStatus { .notRegistered }

  func register() async throws {
    lock.withLock { registerCount += 1 }
    await withCheckedContinuation { continuation in
      lock.withLock { pending = continuation }
    }
  }

  func unregister() async throws {
    lock.withLock { unregisterCount += 1 }
  }
  func openSystemSettingsLoginItems() {}

  var registerCalls: Int { lock.withLock { registerCount } }
  var unregisterCalls: Int { lock.withLock { unregisterCount } }

  func waitUntilRegisterSuspended() async -> Bool {
    // Poll with a small delay rather than bare yields: under load (e.g. a busy
    // CI VM) the detached register() task may not have suspended within a fixed
    // number of cooperative yields, which made this intermittently flaky.
    for _ in 0..<500 {
      if lock.withLock({ pending != nil }) {
        return true
      }
      try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return false
  }

  func resumeRegister() -> Bool {
    let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      let continuation = pending
      pending = nil
      return continuation
    }
    guard let continuation else {
      return false
    }
    continuation.resume()
    return true
  }
}

private final class CountingLoginItemService: LoginItemServiceManaging, @unchecked Sendable {
  private let lock = NSLock()
  private var registerCount = 0
  private var unregisterCount = 0
  var status: ServiceRegistrationStatus

  init(status: ServiceRegistrationStatus) {
    self.status = status
  }

  func register() async throws {
    lock.withLock { registerCount += 1 }
  }

  func unregister() async throws {
    lock.withLock { unregisterCount += 1 }
  }

  func openSystemSettingsLoginItems() {}

  var registerCalls: Int { lock.withLock { registerCount } }
  var unregisterCalls: Int { lock.withLock { unregisterCount } }
}

private struct StubLoginItemService: LoginItemServiceManaging {
  var status: ServiceRegistrationStatus { .enabled }
  func register() async throws {}
  func unregister() async throws {}
  func openSystemSettingsLoginItems() {}
}

private struct StubAgentClient: AgentClientProtocol {
  func status() async throws -> AgentStatus { Self.makeStatus() }
  func reloadConfiguration() async throws -> AgentStatus { Self.makeStatus() }
  func requestAccessibilityPrompt() {}
  func requestInputMonitoringPrompt() {}

  private static func makeStatus() -> AgentStatus {
    AgentStatus(
      agentVersion: "test",
      accessibilityGranted: true,
      inputMonitoringGranted: true,
      tapActive: true,
      configState: .ok,
      bindingCount: 0,
      lastReloadError: nil
    )
  }
}

private struct ThrowingAgentClient: AgentClientProtocol {
  func status() async throws -> AgentStatus {
    throw CocoaError(.xpcConnectionInvalid)
  }

  func reloadConfiguration() async throws -> AgentStatus {
    throw CocoaError(.xpcConnectionInvalid)
  }

  func requestAccessibilityPrompt() {}
  func requestInputMonitoringPrompt() {}
}
