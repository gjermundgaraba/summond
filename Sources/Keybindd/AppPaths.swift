import Foundation

enum AppPaths {
  static var configFile: String {
    "\(homeDirectory)/.config/keybindd/config.toml"
  }

  static var pidFile: String {
    "\(homeDirectory)/.config/keybindd/keybindd.pid"
  }

  private static var homeDirectory: String {
    FileManager.default.homeDirectoryForCurrentUser.path
  }
}
