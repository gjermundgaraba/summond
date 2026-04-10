import Foundation

struct Logger: Sendable {
  let verbose: Bool

  init(verbose: Bool = false) {
    self.verbose = verbose
  }

  func info(_ message: String) {
    write("[keybindd] \(message)\n")
  }

  func warning(_ message: String) {
    write("[keybindd] WARNING: \(message)\n")
  }

  func error(_ message: String) {
    write("[keybindd] ERROR: \(message)\n")
  }

  func debug(_ message: String) {
    guard verbose else {
      return
    }

    write("[keybindd] DEBUG: \(message)\n")
  }

  private func write(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
  }
}
