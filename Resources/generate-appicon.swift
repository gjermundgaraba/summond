import AppKit

// Generates the Summond app icon: press a key, summon a window.

let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.2237, yRadius: size * 0.2237)
path.addClip()
let grad = NSGradient(colors: [
  NSColor(srgbRed: 0.46, green: 0.28, blue: 0.95, alpha: 1),
  NSColor(srgbRed: 0.85, green: 0.12, blue: 0.55, alpha: 1),
])!
grad.draw(in: rect, angle: -90)

let capW = 672.0
let capH = 672.0
let capX = (size - capW) / 2
let capY = (size - capH) / 2
let capRect = NSRect(x: capX, y: capY, width: capW, height: capH)
let capRadius = 132.0
NSColor.white.setFill()
NSBezierPath(roundedRect: capRect, xRadius: capRadius, yRadius: capRadius).fill()

let cutW = 384.0
let cutH = 296.0
let cutX = (size - cutW) / 2
let cutY = (size - cutH) / 2 + 24 // slightly below cap center for visual balance
let cutRect = NSRect(x: cutX, y: cutY, width: cutW, height: cutH)
let cutRadius = 44.0
NSGraphicsContext.current!.compositingOperation = .clear
NSBezierPath(roundedRect: cutRect, xRadius: cutRadius, yRadius: cutRadius).fill()

NSGraphicsContext.current!.compositingOperation = .sourceOver
let dividerH = 30.0
let dividerY = cutY + cutH - 84.0 // ~title-bar band from the top
let dividerRect = NSRect(x: cutX, y: dividerY, width: cutW, height: dividerH)
NSColor.white.setFill()
NSBezierPath(rect: dividerRect).fill()

func sparklePath(center: NSPoint, r: CGFloat) -> NSBezierPath {
  let p = NSBezierPath()
  let cx = center.x, cy = center.y
  let k = 0.34 // concavity: smaller = pointier star
  p.move(to: NSPoint(x: cx, y: cy + r))
  p.curve(to: NSPoint(x: cx + r, y: cy),
          controlPoint1: NSPoint(x: cx + k * r, y: cy + k * r),
          controlPoint2: NSPoint(x: cx + k * r, y: cy + k * r))
  p.curve(to: NSPoint(x: cx, y: cy - r),
          controlPoint1: NSPoint(x: cx + k * r, y: cy - k * r),
          controlPoint2: NSPoint(x: cx + k * r, y: cy - k * r))
  p.curve(to: NSPoint(x: cx - r, y: cy),
          controlPoint1: NSPoint(x: cx - k * r, y: cy - k * r),
          controlPoint2: NSPoint(x: cx - k * r, y: cy - k * r))
  p.curve(to: NSPoint(x: cx, y: cy + r),
          controlPoint1: NSPoint(x: cx - k * r, y: cy + k * r),
          controlPoint2: NSPoint(x: cx - k * r, y: cy + k * r))
  p.close()
  return p
}

let sparkR = 132.0
let sparkCenter = NSPoint(x: capX + capW - 36.0, y: capY + capH + 12.0)
NSColor.white.setFill()
sparklePath(center: sparkCenter, r: sparkR).fill()

img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "/tmp/iconwork/icon_1024.png"))
print("wrote icon_1024.png")
