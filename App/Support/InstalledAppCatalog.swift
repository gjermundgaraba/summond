import AppKit
import Foundation
import SummondCore

protocol AppDisplayResolving {
  @MainActor func displayInfo(for bundleID: String) -> AppDisplayInfo
  @MainActor func identity(forApplicationURL url: URL) -> AppIdentity?
  @MainActor func installedApplications() async -> [AppDisplayInfo]
}

@MainActor
final class InstalledAppCatalog: AppDisplayResolving {
  private let enumerator = InstalledApplicationEnumerator()

  /// Resolves lightweight metadata for a bundle id. Deliberately uncached so an
  /// app that is uninstalled mid-session is reported as missing, and icon-free
  /// so the expensive icon decode stays off the render path — views load icons
  /// asynchronously through `AppIconCache`.
  func displayInfo(for bundleID: String) -> AppDisplayInfo {
    guard
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
      let identity = InstalledAppResolver.identity(forApplicationURL: url)
    else {
      return .missing(bundleID: bundleID)
    }

    return .installed(
      bundleID: identity.bundleIdentifier,
      displayName: appDisplayName(for: identity.bundleURL),
      url: identity.bundleURL
    )
  }

  func identity(forApplicationURL url: URL) -> AppIdentity? {
    InstalledAppResolver.identity(forApplicationURL: url)
  }

  func installedApplications() async -> [AppDisplayInfo] {
    await enumerator.installedApplications().map { item in
      .installed(bundleID: item.bundleID, displayName: item.displayName, url: item.url)
    }
  }
}

private struct InstalledApplicationMetadata: Sendable {
  var bundleID: String
  var displayName: String
  var url: URL
}

private actor InstalledApplicationEnumerator {
  func installedApplications() -> [InstalledApplicationMetadata] {
    let urls = Self.standardApplicationDirectories().flatMap(Self.applicationURLs(in:))
    var appsByBundleID: [String: InstalledApplicationMetadata] = [:]

    for url in urls {
      guard let identity = InstalledAppResolver.identity(forApplicationURL: url) else {
        continue
      }

      appsByBundleID[identity.bundleIdentifier] = InstalledApplicationMetadata(
        bundleID: identity.bundleIdentifier,
        displayName: appDisplayName(for: identity.bundleURL),
        url: identity.bundleURL
      )
    }

    return appsByBundleID.values.sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
  }

  private static func standardApplicationDirectories() -> [URL] {
    let fileManager = FileManager.default
    var urls = fileManager.urls(
      for: .applicationDirectory, in: [.localDomainMask, .systemDomainMask])
    urls.append(contentsOf: fileManager.urls(for: .applicationDirectory, in: .userDomainMask))
    urls.append(URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true))
    return Array(Set(urls)).sorted { $0.path < $1.path }
  }

  private static func applicationURLs(in directory: URL) -> [URL] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey, .contentTypeKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }

    var urls: [URL] = []
    for case let url as URL in enumerator {
      guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
        continue
      }
      urls.append(url)
      enumerator.skipDescendants()
    }
    return urls
  }
}

private func appDisplayName(for url: URL) -> String {
  FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
}
