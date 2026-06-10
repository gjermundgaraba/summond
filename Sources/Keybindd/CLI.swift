import ArgumentParser
import Foundation

@main
struct KeybinddCLI: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "keybindd",
    abstract: "Global keybind daemon for macOS",
    subcommands: [Start.self, Stop.self, Config.self]
  )
}

extension KeybinddCLI {
  struct Start: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Start the keybindd daemon (foreground)"
    )

    @Option(name: .long, help: "Path to config file")
    var config: String = AppPaths.configFile

    @Flag(name: .long, help: "Log all key events for debugging")
    var verbose: Bool = false

    func run() throws {
      let logger = Logger(verbose: verbose)
      Daemon(configPath: config, runtime: MacOSAppRuntime(logger: logger), logger: logger).start()
    }
  }

  struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Stop the running keybindd daemon"
    )

    func run() throws {
      try KeybinddCLI.signalRunningDaemon(SIGTERM, action: "Sent SIGTERM")
    }
  }
}

extension KeybinddCLI {
  struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Manage app binding config file",
      subcommands: [List.self, Add.self, Remove.self, Validate.self]
    )
  }
}

extension KeybinddCLI.Config {
  struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "List configured app bindings"
    )

    @Option(name: .long, help: "Path to config file")
    var config: String = AppPaths.configFile

    func run() throws {
      guard FileManager.default.fileExists(atPath: config) else {
        print("No config file found at '\(config)'")
        return
      }

      do {
        let result = try BindingConfigStore.load(from: config)
        guard !result.bindings.isEmpty else {
          print("No bindings configured")
          return
        }

        print("\(result.bindings.count) binding(s):")
        for (index, binding) in result.bindings.enumerated() {
          print("  \(index + 1). \(KeybinddCLI.bindingSummary(binding))")
        }
      } catch {
        try KeybinddCLI.fail(error)
      }
    }
  }

  struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Add an app binding to the config"
    )

    @Option(name: .long, help: "Path to config file")
    var config: String = AppPaths.configFile

    @Option(name: .long, help: "Key name (e.g. f5, space, a)")
    var key: String

    @Option(name: .long, help: "Comma-separated modifiers (e.g. cmd,shift)")
    var mods: String = ""

    @Option(
      name: .long,
      help: "App bundle identifier (e.g. com.apple.Safari). Alternative to --application-path"
    )
    var bundleID: String?

    @Option(
      name: .long,
      help:
        "Path to an application bundle (e.g. /Applications/Safari.app). Alternative to --bundle-id"
    )
    var applicationPath: String?

    @Option(name: .long, help: "Open mode: launch, new-window, or move")
    var mode: String

    func validate() throws {
      switch (bundleID, applicationPath) {
      case (nil, nil):
        throw ValidationError("Pass either --bundle-id or --application-path")
      case (.some, .some):
        throw ValidationError("Pass either --bundle-id or --application-path, not both")
      default:
        break
      }
    }

    func run() throws {
      do {
        let binding = try KeybinddCLI.binding(
          key: key,
          mods: mods,
          bundleID: try KeybinddCLI.resolvedBundleID(
            bundleID: bundleID,
            applicationPath: applicationPath
          ),
          mode: mode
        )
        let added = try BindingConfigStore.add(
          binding,
          to: config,
          resolver: InstalledAppResolver()
        )
        print("Added binding: \(KeybinddCLI.bindingSummary(added))")
      } catch {
        try KeybinddCLI.fail(error)
      }
    }
  }

  struct Remove: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Remove an app binding from the config"
    )

    @Option(name: .long, help: "Path to config file")
    var config: String = AppPaths.configFile

    @Option(name: .long, help: "Key name to match")
    var key: String

    @Option(name: .long, help: "Comma-separated modifiers to match (omit to match by key only)")
    var mods: String?

    func run() throws {
      guard FileManager.default.fileExists(atPath: config) else {
        print("Config file not found at '\(config)'")
        throw ExitCode.failure
      }

      do {
        let selector = try KeybinddCLI.selector(key: key, mods: mods)
        let removed = try BindingConfigStore.remove(selector, from: config)
        print("Removed binding: \(KeybinddCLI.bindingSummary(removed))")
      } catch {
        try KeybinddCLI.fail(error)
      }
    }
  }

  struct Validate: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Validate the config against the current machine"
    )

    @Option(name: .long, help: "Path to config file")
    var config: String = AppPaths.configFile

    func run() throws {
      guard FileManager.default.fileExists(atPath: config) else {
        print("Config file not found at '\(config)'")
        throw ExitCode.failure
      }

      do {
        let result = try BindingConfigStore.load(from: config)
        print("Validated \(result.snapshot.count) binding(s)")
      } catch {
        try KeybinddCLI.fail(error)
      }
    }
  }
}

extension KeybinddCLI {
  fileprivate static func signalRunningDaemon(_ signalNumber: Int32, action: String) throws {
    let record = try liveDaemonRecord()
    guard kill(record.pid, signalNumber) == 0 else {
      let error = String(cString: strerror(errno))
      if errno == ESRCH {
        PidFile.removeStaleRecord(PidFileRecord(pid: record.pid, isAlive: false))
      }
      print("Failed to signal daemon (PID \(record.pid)): \(error)")
      throw ExitCode.failure
    }

    print("\(action) to daemon (PID \(record.pid))")
  }

  fileprivate static func liveDaemonRecord() throws -> PidFileRecord {
    guard let record = PidFile.locate() else {
      print("No running daemon found (no PID file)")
      throw ExitCode.failure
    }

    guard record.isAlive else {
      print("Stale PID file (process \(record.pid) not running), cleaning up")
      PidFile.removeStaleRecord(record)
      throw ExitCode.failure
    }

    return record
  }

  static func resolvedBundleID(bundleID: String?, applicationPath: String?) throws -> String {
    if let bundleID {
      return bundleID
    }

    guard let applicationPath else {
      throw ValidationError("Pass either --bundle-id or --application-path")
    }

    guard let identity = InstalledAppResolver.identity(forApplicationPath: applicationPath) else {
      throw ValidationError("Application path '\(applicationPath)' is not a valid app bundle")
    }

    return identity.bundleIdentifier
  }

  fileprivate static func binding(
    key: String,
    mods: String,
    bundleID: String,
    mode: String
  ) throws -> AppBinding {
    let shortcut = Shortcut(key: key, mods: parsedModifiers(mods))
    let openMode = try AppOpenMode(parsing: mode)
    let app = try AppTarget(bundleID: bundleID, mode: openMode)
    return AppBinding(shortcut: shortcut, app: app)
  }

  fileprivate static func selector(key: String, mods: String?) throws -> BindingSelector {
    if let mods {
      let shortcut = Shortcut(key: key, mods: parsedModifiers(mods))
      let compiled = try BindingCompiler.compileShortcut(shortcut)
      return .shortcut(compiled, description: shortcut.description)
    }

    let shortcut = Shortcut(key: key, mods: [])
    let compiled = try BindingCompiler.compileShortcut(shortcut)
    return .key(keyCode: compiled.keyCode, description: key.lowercased())
  }

  fileprivate static func parsedModifiers(_ value: String) -> [String] {
    guard !value.isEmpty else { return [] }
    return value.split(separator: ",").map {
      String($0).trimmingCharacters(in: .whitespaces)
    }
  }

  fileprivate static func bindingSummary(_ binding: AppBinding) -> String {
    "\(binding.description) -> \(binding.app.bundleID) [\(binding.app.mode.cliValue)]"
  }

  fileprivate static func fail(_ error: Error) throws -> Never {
    print(error.localizedDescription)
    throw ExitCode.failure
  }
}
