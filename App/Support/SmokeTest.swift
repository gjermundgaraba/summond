#if SMOKE_TEST
  import Foundation
  import SummondCore

  /// SMOKE_TEST entry point for `make smoke-tart`; connects to the bootstrapped
  /// agent and writes one status round-trip result for the shell harness.
  @main
  enum SmokeTest {
    static func main() {
      let outputPath = parsedOption("--smoke-output")
      Task {
        let exitCode = await run(writingResultTo: outputPath)
        exit(exitCode)
      }
      // Service the XPC reply and the async Task on the main dispatch queue until
      // the Task calls exit(). No NSApplication/run loop is needed for XPC.
      dispatchMain()
    }

    private static func run(writingResultTo outputPath: String?) async -> Int32 {
      do {
        let status = try await AgentClient().status()
        report(
          outputPath,
          "smoke: ok agentVersion=\(status.agentVersion) "
            + "configState=\(status.configState.rawValue) bindingCount=\(status.bindingCount)"
        )
        return 0
      } catch {
        report(outputPath, "smoke: fail \(error.localizedDescription)")
        return 1
      }
    }

    private static func parsedOption(_ name: String) -> String? {
      let args = CommandLine.arguments
      guard let index = args.firstIndex(of: name), index + 1 < args.count else {
        return nil
      }
      return args[index + 1]
    }

    private static func report(_ outputPath: String?, _ message: String) {
      FileHandle.standardError.write(Data((message + "\n").utf8))
      guard let outputPath else {
        return
      }
      try? (message + "\n").write(toFile: outputPath, atomically: true, encoding: .utf8)
    }
  }
#endif
