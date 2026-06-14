import AppKit

@MainActor
final class AppIconCache {
  static let shared = AppIconCache()

  private var cache: [String: NSImage] = [:]
  private var inFlight: [String: Task<NSImage, Never>] = [:]

  private init() {}

  func cached(_ url: URL) -> NSImage? {
    cache[url.path]
  }

  func load(_ url: URL) async -> NSImage {
    let path = url.path
    if let hit = cache[path] {
      return hit
    }

    if let task = inFlight[path] {
      return await task.value
    }

    let task = Task { @MainActor in
      let image = NSWorkspace.shared.icon(forFile: path)
      image.size = NSSize(width: 32, height: 32)
      return image
    }
    inFlight[path] = task

    let image = await task.value
    cache[path] = image
    inFlight[path] = nil
    return image
  }
}
