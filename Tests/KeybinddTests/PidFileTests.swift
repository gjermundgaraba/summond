import Foundation
import Testing

@testable import keybindd

@Suite("PID file locking")
struct PidFileTests {
  @Test("Concurrent acquires allow only one winner")
  func concurrentAcquireOnlySucceedsOnce() async throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let store = PidFileStore(
      path: tmpDir.appendingPathComponent("keybindd.pid").path,
      currentPID: { Int32.random(in: 1000...9999) },
      processChecker: { _ in true }
    )

    async let first = store.acquire()
    async let second = store.acquire()
    async let third = store.acquire()
    let results = await [first, second, third]

    #expect(results.filter { $0 }.count == 1)
  }

  @Test("Acquire refuses to start when pidfile is live")
  func acquireHonorsLivePidfile() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let livePID: pid_t = 4242
    try "\(livePID)".write(
      to: tmpDir.appendingPathComponent("keybindd.pid"),
      atomically: true,
      encoding: .utf8
    )

    let store = PidFileStore(
      path: tmpDir.appendingPathComponent("keybindd.pid").path,
      currentPID: { 1111 },
      processChecker: { $0 == livePID }
    )

    #expect(store.acquire() == false)
  }

  @Test("Locate returns the current pidfile record")
  func locateReturnsCurrentPid() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let currentPID: pid_t = 2222

    try "\(currentPID)".write(
      to: tmpDir.appendingPathComponent("keybindd.pid"),
      atomically: true,
      encoding: .utf8
    )

    let store = PidFileStore(
      path: tmpDir.appendingPathComponent("keybindd.pid").path,
      currentPID: { 3333 },
      processChecker: { $0 == currentPID }
    )

    let record = store.locate()
    #expect(record?.pid == currentPID)
    #expect(record?.isAlive == true)
  }

  @Test("Locate ignores invalid pidfile contents")
  func locateIgnoresInvalidPidfileContents() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let pidFile = tmpDir.appendingPathComponent("keybindd.pid")
    try "0".write(to: pidFile, atomically: true, encoding: .utf8)

    let store = PidFileStore(
      path: pidFile.path,
      currentPID: { 3333 },
      processChecker: { _ in true }
    )

    #expect(store.locate() == nil)
  }

  @Test("Removing stale record does not delete a newer pidfile")
  func removeStaleRecordLeavesNewerPidfileAlone() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let pidFile = tmpDir.appendingPathComponent("keybindd.pid")
    try "1111".write(to: pidFile, atomically: true, encoding: .utf8)

    let store = PidFileStore(
      path: pidFile.path,
      currentPID: { 3333 },
      processChecker: { $0 == 2222 }
    )

    try "2222".write(to: pidFile, atomically: true, encoding: .utf8)
    store.removeStaleRecord(PidFileRecord(pid: 1111, isAlive: false))

    let content = try String(contentsOf: pidFile, encoding: .utf8)
    #expect(content.trimmingCharacters(in: .whitespacesAndNewlines) == "2222")
  }
}
