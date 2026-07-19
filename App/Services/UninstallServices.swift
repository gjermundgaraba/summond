import AppKit
import Foundation
import SummondCore

protocol SavedDataRemoving: Sendable {
  func removeAllSavedData()
}

struct UserDefaultsSavedDataRemover: SavedDataRemoving {
  static let summondDomainNames = [
    SummondBundleIdentifiers.app,
    UserDefaultsConfigurationStore.defaultSuiteName,
    SummondBundleIdentifiers.agent,
    SummondBundleIdentifiers.statusItem,
  ]

  private let domainNames: [String]

  init(domainNames: [String] = Self.summondDomainNames) {
    self.domainNames = domainNames
  }

  func removeAllSavedData() {
    for domainName in domainNames {
      UserDefaults.standard.removePersistentDomain(forName: domainName)
    }
  }
}

@MainActor
protocol UninstallApplicationManaging {
  func revealInFinderAndTerminate(applicationURL: URL)
}

@MainActor
struct UninstallApplicationManager: UninstallApplicationManaging {
  func revealInFinderAndTerminate(applicationURL: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([applicationURL])
    NSApplication.shared.terminate(nil)
  }
}
