import AppKit

/// A per-path cache of app icons, resolved on the main actor.
@MainActor
final class AppIconCache {
  static let shared = AppIconCache()

  private var cache: [String: NSImage] = [:]

  private init() {}

  func icon(for url: URL) -> NSImage {
    let path = url.path
    if let hit = cache[path] {
      return hit
    }

    let image = NSWorkspace.shared.icon(forFile: path)
    image.size = NSSize(width: 32, height: 32)
    cache[path] = image
    return image
  }
}
