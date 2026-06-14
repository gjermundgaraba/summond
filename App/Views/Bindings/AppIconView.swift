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
    AppIconView(image: image, size: size)
      .task(id: url) {
        guard let url else {
          image = nil
          return
        }
        image = nil
        if let hit = AppIconCache.shared.cached(url) {
          guard !Task.isCancelled else {
            return
          }
          image = hit
        } else {
          let loadedImage = await AppIconCache.shared.load(url)
          guard !Task.isCancelled, self.url == url else {
            return
          }
          image = loadedImage
        }
      }
  }
}
