import OSLog
import Synchronization

public final class VerboseLoggingState: Sendable {
  private let enabled: Atomic<Bool>

  public init(isEnabled: Bool = false) {
    self.enabled = Atomic(isEnabled)
  }

  public var isEnabled: Bool {
    enabled.load(ordering: .relaxed)
  }

  func setEnabled(_ isEnabled: Bool) {
    enabled.store(isEnabled, ordering: .relaxed)
  }
}

public enum SummondLoggers {
  public static let subsystem = "net.garaba.summond"

  public static let engine = Logger(subsystem: subsystem, category: "engine")
  public static let opener = Logger(subsystem: subsystem, category: "opener")
  public static let config = Logger(subsystem: subsystem, category: "config")
  public static let spaces = Logger(subsystem: subsystem, category: "spaces")
  public static let agent = Logger(subsystem: subsystem, category: "agent")
  public static let xpc = Logger(subsystem: subsystem, category: "xpc")
}
