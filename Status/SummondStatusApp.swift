import AppKit
import SummondCore
import Observation
import SwiftUI

@main
struct SummondStatusApp: App {
  @State private var model = StatusMenuModel()

  var body: some Scene {
    MenuBarExtra {
      StatusMenuContent(model: model)
    } label: {
      StatusMenuLabel(presentation: model.presentation)
    }
    .menuBarExtraStyle(.menu)
  }
}

private struct StatusMenuLabel: View {
  var presentation: StatusItemPresentation

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Image(systemName: "keyboard")
      if presentation.showsWarningBadge {
        Image(systemName: "exclamationmark.circle.fill")
          .font(.system(size: 8, weight: .bold))
          .symbolRenderingMode(.palette)
          .foregroundStyle(.white, .orange)
          .offset(x: 5, y: -4)
      }
    }
    .accessibilityLabel("Summond")
  }
}

private struct StatusMenuContent: View {
  var model: StatusMenuModel

  var body: some View {
    Text(model.presentation.statusLine)
      .font(.headline)

    Divider()

    Button("Open Summond") {
      model.openPreferences()
    }

    Button("Reload Bindings") {
      Task {
        await model.reloadBindings()
      }
    }
    .disabled(!model.presentation.canReload)

    Divider()

    Button("Quit Status Item") {
      NSApp.terminate(nil)
    }
    .onAppear {
      Task {
        await model.refresh()
      }
    }
  }
}

@MainActor
@Observable
private final class StatusMenuModel {
  private var agentStatus: AgentStatus?

  private let agentClient: any AgentClientProtocol
  @ObservationIgnored
  private var refreshTask: Task<Void, Never>?

  init(agentClient: any AgentClientProtocol = AgentClient()) {
    self.agentClient = agentClient
    refreshTask = Task { [weak self] in
      await self?.runRefreshLoop()
    }
  }

  deinit {
    refreshTask?.cancel()
  }

  var presentation: StatusItemPresentation {
    StatusItemPresentationMapper.presentation(agentStatus: agentStatus)
  }

  func refresh() async {
    agentStatus = try? await agentClient.status()
  }

  func reloadBindings() async {
    agentStatus = try? await agentClient.reloadConfiguration()
  }

  func openPreferences() {
    guard let url = URL(string: "summond://preferences") else {
      launchMainApplication()
      return
    }

    if !NSWorkspace.shared.open(url) {
      launchMainApplication()
    }
  }

  private func runRefreshLoop() async {
    await refresh()
    while !Task.isCancelled {
      try? await Task.sleep(nanoseconds: 30_000_000_000)
      await refresh()
    }
  }

  private func launchMainApplication() {
    guard let mainApplicationURL = Self.mainApplicationURL() else {
      return
    }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.openApplication(at: mainApplicationURL, configuration: configuration)
  }

  private static func mainApplicationURL() -> URL? {
    var candidate = Bundle.main.bundleURL.deletingLastPathComponent()
    for _ in 0..<7 {
      if candidate.pathExtension == "app",
        Bundle(url: candidate)?.bundleIdentifier == "net.garaba.summond"
      {
        return candidate
      }
      candidate = candidate.deletingLastPathComponent()
    }

    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.garaba.summond")
  }
}
