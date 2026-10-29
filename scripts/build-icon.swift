// A code-drawn macOS icon: paper, ink, and nenva's blue bookmark.
// Run from the project root with `npm run build:icon`.
import AppKit

let fileManager = FileManager.default
let output = URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent("build")
let iconset = fileManager.temporaryDirectory.appendingPathComponent("notebook-\(UUID().uuidString).iconset")
try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: iconset) }

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func drawIcon(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(size) / 1024)
    scale.concat()

    let tile = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 198, yRadius: 198)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.14)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 20
    shadow.set()
    color(0xf5f5f3).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    color(0xe4e4e0).setStroke()
    tile.lineWidth = 2
    tile.stroke()

    let book = NSBezierPath(roundedRect: NSRect(x: 262, y: 214, width: 512, height: 620), xRadius: 48, yRadius: 48)
    color(0x242423).setFill()
    book.fill()
    let pages = NSBezierPath(roundedRect: NSRect(x: 288, y: 226, width: 465, height: 68), xRadius: 27, yRadius: 27)
    color(0xe4e4e0).setFill()
    pages.fill()
    let cover = NSBezierPath(roundedRect: NSRect(x: 262, y: 278, width: 512, height: 556), xRadius: 48, yRadius: 48)
    color(0x171717).setFill()
    cover.fill()

    let spine = NSBezierPath()
    spine.move(to: NSPoint(x: 333, y: 320))
    spine.line(to: NSPoint(x: 333, y: 790))
    spine.lineWidth = 3
    color(0x4f4f4c).setStroke()
    spine.stroke()
    for (y, width) in [(655.0, 224.0), (589.0, 224.0), (523.0, 148.0)] {
        color(0xececea).setFill()
        NSBezierPath(roundedRect: NSRect(x: 397, y: y, width: width, height: 14), xRadius: 7, yRadius: 7).fill()
    }
    let ribbon = NSBezierPath()
    ribbon.move(to: NSPoint(x: 651, y: 834))
    ribbon.line(to: NSPoint(x: 717, y: 834))
    ribbon.line(to: NSPoint(x: 717, y: 665))
    ribbon.line(to: NSPoint(x: 684, y: 693))
    ribbon.line(to: NSPoint(x: 651, y: 665))
    ribbon.close()
    color(0x2f6bff).setFill()
    ribbon.fill()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let suffix = multiplier == 2 ? "@2x" : ""
        try drawIcon(size: points * multiplier).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
try drawIcon(size: 1024).write(to: output.appendingPathComponent("icon.png"))
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("icon.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Created build/icon.icns and build/icon.png")
