import AppKit
import SwiftUI

struct AppIconView: View {
  var image: NSImage?
  var size: CGFloat = 28

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
      } else {
        Image(systemName: "app.dashed")
          .resizable()
          .foregroundStyle(.secondary)
          .padding(4)
      }
    }
    .aspectRatio(contentMode: .fit)
    .frame(width: size, height: size)
  }
}

struct AppRowIcon: View {
  let url: URL?
  var size: CGFloat = 24

  @State private var image: NSImage?

  var body: some View {
    // Resolve the icon off `body`, re-running when a reused row's URL changes.
    AppIconView(image: image, size: size)
      .task(id: url) {
        image = url.map { AppIconCache.shared.icon(for: $0) }
      }
  }
}
