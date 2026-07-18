import AppKit

// Generates the Summond app icon: press a key, summon a window.
//
// Draws the icon once in a 1024x1024 coordinate space, renders it at every size
// macOS wants in an `.iconset`, and runs `iconutil` to produce `AppIcon.icns`.
// Rendering happens in an explicit offscreen bitmap (no screen/lockFocus), so
// the result does not depend on the current display or working directory.
//
// Usage: swift generate-appicon.swift [output.icns]
//   Default output: Resources/AppIcon.icns next to this script.

// MARK: - Drawing (1024x1024 coordinate space)

func drawIcon() {
  let size = 1024.0
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
  let cutY = (size - cutH) / 2 + 24  // slightly below cap center for visual balance
  let cutRect = NSRect(x: cutX, y: cutY, width: cutW, height: cutH)
  let cutRadius = 44.0
  NSGraphicsContext.current!.compositingOperation = .clear
  NSBezierPath(roundedRect: cutRect, xRadius: cutRadius, yRadius: cutRadius).fill()

  NSGraphicsContext.current!.compositingOperation = .sourceOver
  let dividerH = 30.0
  let dividerY = cutY + cutH - 84.0  // ~title-bar band from the top
  let dividerRect = NSRect(x: cutX, y: dividerY, width: cutW, height: dividerH)
  NSColor.white.setFill()
  NSBezierPath(rect: dividerRect).fill()

  let sparkR = 132.0
  let sparkCenter = NSPoint(x: capX + capW - 36.0, y: capY + capH + 12.0)
  NSColor.white.setFill()
  sparklePath(center: sparkCenter, r: sparkR).fill()
}

func sparklePath(center: NSPoint, r: CGFloat) -> NSBezierPath {
  let p = NSBezierPath()
  let cx = center.x
  let cy = center.y
  let k = 0.34  // concavity: smaller = pointier star
  p.move(to: NSPoint(x: cx, y: cy + r))
  p.curve(
    to: NSPoint(x: cx + r, y: cy),
    controlPoint1: NSPoint(x: cx + k * r, y: cy + k * r),
    controlPoint2: NSPoint(x: cx + k * r, y: cy + k * r))
  p.curve(
    to: NSPoint(x: cx, y: cy - r),
    controlPoint1: NSPoint(x: cx + k * r, y: cy - k * r),
    controlPoint2: NSPoint(x: cx + k * r, y: cy - k * r))
  p.curve(
    to: NSPoint(x: cx - r, y: cy),
    controlPoint1: NSPoint(x: cx - k * r, y: cy - k * r),
    controlPoint2: NSPoint(x: cx - k * r, y: cy - k * r))
  p.curve(
    to: NSPoint(x: cx, y: cy + r),
    controlPoint1: NSPoint(x: cx - k * r, y: cy + k * r),
    controlPoint2: NSPoint(x: cx - k * r, y: cy + k * r))
  p.close()
  return p
}

// MARK: - Rendering

func renderPNG(pixelSize: Int) -> Data {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixelSize,
    pixelsHigh: pixelSize,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0)!
  guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
    fatalError("could not create a bitmap graphics context")
  }
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = ctx
  let scale = CGFloat(pixelSize) / 1024.0
  let transform = NSAffineTransform()
  transform.scale(by: scale)
  transform.concat()
  drawIcon()
  NSGraphicsContext.restoreGraphicsState()
  guard let data = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not encode PNG at \(pixelSize)px")
  }
  return data
}

// MARK: - Main

// (pointSize, scale) -> iconset filename, per Apple's AppIcon.iconset layout.
let variants: [(point: Int, scale: Int)] = [
  (16, 1), (16, 2),
  (32, 1), (32, 2),
  (128, 1), (128, 2),
  (256, 1), (256, 2),
  (512, 1), (512, 2),
]

let fileManager = FileManager.default
let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let output =
  CommandLine.arguments.count > 1
  ? URL(fileURLWithPath: CommandLine.arguments[1])
  : scriptDir.appendingPathComponent("AppIcon.icns")

let workDir = fileManager.temporaryDirectory.appendingPathComponent(
  "summond-iconwork-\(ProcessInfo.processInfo.processIdentifier)")
let iconset = workDir.appendingPathComponent("AppIcon.iconset")
try? fileManager.removeItem(at: workDir)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: workDir) }

for variant in variants {
  let pixels = variant.point * variant.scale
  let suffix = variant.scale == 1 ? "" : "@\(variant.scale)x"
  let name = "icon_\(variant.point)x\(variant.point)\(suffix).png"
  try renderPNG(pixelSize: pixels).write(to: iconset.appendingPathComponent(name))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", iconset.path, "--output", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
  fatalError("iconutil failed with status \(iconutil.terminationStatus)")
}

print("wrote \(output.path)")
