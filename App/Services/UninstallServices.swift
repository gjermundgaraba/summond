import AppKit
import Foundation
import SummondCore

protocol SavedDataRemoving: Sendable {
  func removeAllSavedData() throws
}

struct LocalSavedDataRemover: SavedDataRemoving {
  static let summondDomainNames = [
    SummondBundleIdentifiers.app,
    SummondBundleIdentifiers.agent,
    SummondBundleIdentifiers.statusItem,
  ]

  private let domainNames: [String]
  private let configurationDirectoryURL: URL

  init(
    domainNames: [String] = Self.summondDomainNames,
    configurationDirectoryURL: URL = FileConfigurationStore.defaultURL.deletingLastPathComponent()
  ) {
    self.domainNames = domainNames
    self.configurationDirectoryURL = configurationDirectoryURL
  }

  func removeAllSavedData() throws {
    do {
      try FileManager.default.removeItem(at: configurationDirectoryURL)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      // Already removed.
    }
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
