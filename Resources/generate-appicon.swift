import AppKit

let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

// Rounded-square background with a pink -> magenta gradient
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.2237, yRadius: size * 0.2237)
path.addClip()
let grad = NSGradient(colors: [
  NSColor(srgbRed: 0.96, green: 0.30, blue: 0.55, alpha: 1),
  NSColor(srgbRed: 0.85, green: 0.12, blue: 0.45, alpha: 1),
])!
grad.draw(in: rect, angle: -90)

// White keyboard glyph, centered
let cfg = NSImage.SymbolConfiguration(pointSize: 560, weight: .semibold)
if let base = NSImage(systemSymbolName: "keyboard.fill", accessibilityDescription: nil)?
  .withSymbolConfiguration(cfg) {
  let s = base.size
  let tinted = NSImage(size: s)
  tinted.lockFocus()
  let r = NSRect(origin: .zero, size: s)
  base.draw(in: r)
  NSColor.white.set()
  r.fill(using: .sourceAtop)
  tinted.unlockFocus()
  let origin = NSPoint(x: (size - s.width) / 2, y: (size - s.height) / 2)
  tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
}

img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "/tmp/iconwork/icon_1024.png"))
print("wrote icon_1024.png")
