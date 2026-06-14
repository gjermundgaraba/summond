import OSLog

public enum KeybinddLoggers {
  public static let subsystem = "net.garaba.keybindd"

  public static let engine = Logger(subsystem: subsystem, category: "engine")
  public static let opener = Logger(subsystem: subsystem, category: "opener")
  public static let config = Logger(subsystem: subsystem, category: "config")
  public static let spaces = Logger(subsystem: subsystem, category: "spaces")
  public static let agent = Logger(subsystem: subsystem, category: "agent")
  public static let xpc = Logger(subsystem: subsystem, category: "xpc")
}
