import AppKit

let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

// Rounded-square background with a "summon/conjure" violet -> magenta gradient.
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.2237, yRadius: size * 0.2237)
path.addClip()
let grad = NSGradient(colors: [
  NSColor(srgbRed: 0.46, green: 0.28, blue: 0.95, alpha: 1), // top: violet / indigo
  NSColor(srgbRed: 0.85, green: 0.12, blue: 0.55, alpha: 1), // bottom: magenta
])!
grad.draw(in: rect, angle: -90)

// Hero glyph: a bold, filled white window (macwindow.fill is unavailable in this
// SDK, so it's hand-drawn to stay solid and legible when shrunk to 32px). The
// title-bar separator and traffic-light dots are punched out so the gradient
// shows through, then they gracefully disappear at tiny sizes leaving a clean
// white window block.
let winW = 620.0
let winH = 480.0
let winX = (size - winW) / 2          // horizontally centered
let winY = (size - winH) / 2 - 55     // slightly low
let winImg = NSImage(size: NSSize(width: winW, height: winH))
winImg.lockFocus()
let winRect = NSRect(x: 0, y: 0, width: winW, height: winH)
NSColor.white.setFill()
NSBezierPath(roundedRect: winRect, xRadius: 44, yRadius: 44).fill()
// Punch title-bar separator + traffic-light dots.
NSGraphicsContext.current!.compositingOperation = .clear
let titleBarH = 112.0
let sepThickness = 9.0
NSBezierPath(rect: NSRect(x: 0, y: winH - titleBarH, width: winW, height: sepThickness)).fill()
let dotR = 19.0
let dotCY = winH - titleBarH / 2
let dotX0 = 64.0
let dotGap = 62.0
for i in 0..<3 {
  let cx = dotX0 + Double(i) * dotGap
  NSBezierPath(ovalIn: NSRect(x: cx - dotR, y: dotCY - dotR, width: dotR * 2, height: dotR * 2)).fill()
}
winImg.unlockFocus()
winImg.draw(at: NSPoint(x: winX, y: winY), from: .zero, operation: .sourceOver, fraction: 1)

// Render an SF Symbol tinted solid white via source-atop.
func tintedSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight) -> NSImage {
  let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
  let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
    .withSymbolConfiguration(cfg)!
  let s = base.size
  let tinted = NSImage(size: s)
  tinted.lockFocus()
  let r = NSRect(origin: .zero, size: s)
  base.draw(in: r)
  NSColor.white.set()
  r.fill(using: .sourceAtop)
  tinted.unlockFocus()
  return tinted
}

// Accent glyph: white sparkles in the upper-right, overlapping the window's top
// corner so the window reads as being summoned / conjured.
let sparkImg = tintedSymbol("sparkles", pointSize: 300, weight: .semibold)
let ss = sparkImg.size
let winRight = winX + winW
let winTop = winY + winH
let sparkCenter = NSPoint(x: winRight - 44, y: winTop + 26)
let sOrigin = NSPoint(x: sparkCenter.x - ss.width / 2, y: sparkCenter.y - ss.height / 2)
sparkImg.draw(at: sOrigin, from: .zero, operation: .sourceOver, fraction: 1)

img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "/tmp/iconwork/icon_1024.png"))
print("wrote icon_1024.png")
