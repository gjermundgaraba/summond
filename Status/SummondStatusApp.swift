import AppKit
import Observation
import SummondCore
import SwiftUI

@main
struct SummondStatusApp: App {
  @State private var model = StatusMenuModel()

  var body: some Scene {
    MenuBarExtra {
      StatusMenuContent(model: model)
    } label: {
      StatusMenuLabel(health: model.health)
    }
    .menuBarExtraStyle(.menu)
  }
}

private struct StatusMenuLabel: View {
  var health: SystemHealth

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Image(systemName: "keyboard")
      if health.needsAttention {
        Image(systemName: "exclamationmark.circle.fill")
          .font(.system(size: 8, weight: .bold))
          .symbolRenderingMode(.palette)
          .foregroundStyle(.white, .orange)
          .offset(x: 5, y: -4)
      }
    }
    .accessibilityLabel("Summond")
    .accessibilityValue(health.statusLine)
  }
}

private struct StatusMenuContent: View {
  var model: StatusMenuModel

  var body: some View {
    Text(model.health.statusLine)

    Divider()

    Button("Open Summond") {
      model.openMainApplication()
    }

    if let recovery = model.health.recovery {
      Button(recovery.title) {
        switch recovery.action {
        case .openMain:
          model.openMainApplication()
        case .openSetup:
          model.openSetup()
        case .openDiagnostics:
          model.openSettings()
        case .retryReload:
          Task { await model.reloadConfiguration() }
        }
      }
      .disabled(model.isReloading)
    }

    Divider()

    Button("Menu Bar Settings…") {
      model.openSettings()
    }
  }
}

enum RecoveryAction {
  case openMain
  case openSetup
  case openDiagnostics
  case retryReload
}

struct Recovery {
  var title: String
  var action: RecoveryAction
}

extension SystemHealth {
  fileprivate var needsAttention: Bool {
    if case .ready = self { return false }
    return true
  }

  fileprivate var statusLine: String {
    switch self {
    case .ready(let activeShortcuts):
      let noun = activeShortcuts == 1 ? "shortcut" : "shortcuts"
      return "Active — \(activeShortcuts) \(noun)"
    case .setupRequired(let requirement):
      switch requirement {
      case .backgroundServiceApprovalRequired:
        return "Approve Background Service"
      case .backgroundServiceNotRegistered, .backgroundServiceNotFound:
        return "Background Service Disabled"
      case .accessibilityPermission:
        return "Needs Accessibility"
      case .inputMonitoringPermission:
        return "Needs Input Monitoring"
      }
    case .degraded(let issue):
      switch issue {
      case .agentUnavailable:
        return "Summond Isn't Responding"
      case .configurationUnavailable:
        return "Configuration Unavailable"
      case .configurationCorrupt:
        return "Configuration Corrupt"
      case .configurationInvalid:
        return "Configuration Invalid"
      case .unresolvedApplications(let bundleIDs):
        let count = bundleIDs.count
        let noun = count == 1 ? "App" : "Apps"
        return "\(count) \(noun) Not Installed"
      case .eventTapFailure(let reason):
        return reason.statusLine
      case .eventTapInactive:
        return "Shortcut Listener Inactive"
      case .reloadFailed:
        return "Configuration Reload Failed"
      }
    }
  }

  fileprivate var recovery: Recovery? {
    switch self {
    case .ready:
      nil
    case .setupRequired:
      Recovery(title: "Finish Setup…", action: .openSetup)
    case .degraded(let issue):
      switch issue {
      case .reloadFailed:
        Recovery(title: "Retry Reload", action: .retryReload)
      case .agentUnavailable, .unresolvedApplications, .eventTapFailure, .eventTapInactive:
        Recovery(title: "Open Summond…", action: .openMain)
      case .configurationUnavailable, .configurationCorrupt, .configurationInvalid:
        Recovery(title: "Open Diagnostics…", action: .openDiagnostics)
      }
    }
  }
}

extension EventTapFailureReason {
  fileprivate var statusLine: String {
    switch self {
    case .accessibilityDenied:
      "Needs Accessibility"
    case .inputMonitoringDenied:
      "Needs Input Monitoring"
    case .installationFailed:
      "Shortcut Listener Unavailable"
    case .disabledByTimeout:
      "Shortcut Listener Timed Out"
    case .disabledByUserInput:
      "Shortcut Listener Disabled"
    case .restartLoopDetected:
      "Shortcut Listener Paused"
    }
  }
}

@MainActor
@Observable
private final class StatusMenuModel {
  private(set) var agentStatus: AgentStatus?
  private(set) var isReloading = false
  private(set) var reloadError: String?

  private let agentClient: any AgentClientProtocol

  init(agentClient: any AgentClientProtocol = AgentClient()) {
    self.agentClient = agentClient
    // The menu bar model is owned by the process-lifetime MenuBarExtra scene and
    // is never torn down, so the poll loop just runs until the process exits.
    Task { [weak self] in
      while let self {
        await self.refresh()
        try? await Task.sleep(nanoseconds: 30_000_000_000)
      }
    }
  }

  var health: SystemHealth {
    if let reloadError {
      return .degraded(.reloadFailed(details: reloadError))
    }
    return SystemHealth.evaluate(agentStatus: agentStatus)
  }

  func refresh() async {
    do {
      agentStatus = try await agentClient.status()
      reloadError = nil
    } catch {
      agentStatus = nil
    }
  }

  func reloadConfiguration() async {
    guard !isReloading else { return }
    isReloading = true
    defer { isReloading = false }
    do {
      agentStatus = try await agentClient.reloadConfiguration()
      reloadError = nil
    } catch {
      reloadError = error.localizedDescription
    }
  }

  func openMainApplication() {
    openMainApplication(path: "preferences")
  }

  func openSetup() {
    openMainApplication(path: "setup")
  }

  func openSettings() {
    openMainApplication(path: "settings")
  }

  private func openMainApplication(path: String) {
    if let url = URL(string: "summond://\(path)"), NSWorkspace.shared.open(url) {
      return
    }

    guard let mainApplicationURL = Self.mainApplicationURL() else { return }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.openApplication(at: mainApplicationURL, configuration: configuration)
  }

  private static func mainApplicationURL() -> URL? {
    var candidate = Bundle.main.bundleURL.deletingLastPathComponent()
    for _ in 0..<7 {
      if candidate.pathExtension == "app",
        Bundle(url: candidate)?.bundleIdentifier == SummondBundleIdentifiers.app
      {
        return candidate
      }
      candidate = candidate.deletingLastPathComponent()
    }

    return NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: SummondBundleIdentifiers.app)
  }
}
