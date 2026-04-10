import Foundation

enum PidFile {
  private static let liveStore = PidFileStore(
    path: AppPaths.pidFile,
    currentPID: { ProcessInfo.processInfo.processIdentifier },
    processChecker: {
      kill($0, 0) == 0 || errno == EPERM
    }
  )

  @discardableResult
  static func acquire(logger: Logger = Logger()) -> Bool {
    liveStore.acquire(logger: logger)
  }

  static func locate() -> PidFileRecord? {
    liveStore.locate()
  }

  static func remove() {
    liveStore.removeOwned()
  }

  static func removeStaleRecord(_ record: PidFileRecord) {
    liveStore.removeStaleRecord(record)
  }
}

struct PidFileRecord: Sendable {
  let pid: pid_t
  let isAlive: Bool
}

final class PidFileStore: @unchecked Sendable {
  let path: String
  let currentPID: @Sendable () -> pid_t
  let processChecker: @Sendable (pid_t) -> Bool
  private let lock = NSLock()
  private var lockedFileDescriptor: Int32?

  init(
    path: String,
    currentPID: @escaping @Sendable () -> pid_t,
    processChecker: @escaping @Sendable (pid_t) -> Bool
  ) {
    self.path = path
    self.currentPID = currentPID
    self.processChecker = processChecker
  }

  @discardableResult
  func acquire(logger: Logger = Logger()) -> Bool {
    let directory = (path as NSString).deletingLastPathComponent
    do {
      try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    } catch {
      logger.error("failed to create PID directory: \(error.localizedDescription)")
      return false
    }

    if let liveRecord = locateLiveRecord() {
      logger.error("another instance is already running (PID \(liveRecord.pid))")
      return false
    }

    return lock.withLock {
      if lockedFileDescriptor != nil {
        return false
      }

      let fd = open(path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
      guard fd >= 0 else {
        logger.error("failed to open PID file: \(String(cString: strerror(errno)))")
        return false
      }

      guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        close(fd)
        return false
      }

      guard ftruncate(fd, 0) == 0 else {
        flock(fd, LOCK_UN)
        close(fd)
        logger.error("failed to truncate PID file")
        return false
      }

      let pid = currentPID()
      let data = Data("\(pid)".utf8)
      let bytesWritten = data.withUnsafeBytes { buffer in
        write(fd, buffer.baseAddress, buffer.count)
      }

      guard bytesWritten == data.count else {
        flock(fd, LOCK_UN)
        close(fd)
        logger.error("failed to write PID file")
        return false
      }

      guard fsync(fd) == 0 else {
        flock(fd, LOCK_UN)
        close(fd)
        logger.error("failed to flush PID file")
        return false
      }

      lockedFileDescriptor = fd
      return true
    }
  }

  func locate() -> PidFileRecord? {
    record()
  }

  func removeOwned() {
    lock.withLock {
      if let fd = lockedFileDescriptor {
        _ = unlink(path)
        flock(fd, LOCK_UN)
        close(fd)
        lockedFileDescriptor = nil
      }
    }
  }

  func removeStaleRecord(_ record: PidFileRecord) {
    guard !record.isAlive else { return }

    let fd = open(path, O_RDWR)
    guard fd >= 0 else { return }
    defer { close(fd) }

    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return }
    defer { flock(fd, LOCK_UN) }

    guard let currentPID = read(fromFileDescriptor: fd), currentPID == record.pid else {
      return
    }

    guard !processChecker(currentPID) else {
      return
    }

    _ = unlink(path)
  }

  private func locateLiveRecord() -> PidFileRecord? {
    guard let record = record(), record.isAlive else {
      return nil
    }
    return record
  }

  private func record() -> PidFileRecord? {
    guard let pid = read(from: path) else {
      return nil
    }

    return PidFileRecord(
      pid: pid,
      isAlive: processChecker(pid)
    )
  }

  private func read(from path: String) -> pid_t? {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
      return nil
    }

    return parsePID(content)
  }

  private func read(fromFileDescriptor fd: Int32) -> pid_t? {
    guard lseek(fd, 0, SEEK_SET) >= 0 else {
      return nil
    }

    var buffer = [UInt8](repeating: 0, count: 64)
    let count = Darwin.read(fd, &buffer, buffer.count)
    guard count > 0 else {
      return nil
    }

    let content = String(decoding: buffer.prefix(count), as: UTF8.self)
    return parsePID(content)
  }

  private func parsePID(_ content: String) -> pid_t? {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pid = pid_t(trimmed), pid > 0 else {
      return nil
    }
    return pid
  }
}
