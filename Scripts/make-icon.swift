// Draws the UTM Watch app icon and writes Resources/AppIcon.icns.
// Usage: swift Scripts/make-icon.swift      (run from the repository root; needs iconutil, part of macOS)
// The icns is committed, so this only needs running when the drawing changes.
import AppKit

func color(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

/// The drawing is laid out on a 220-point square with the tile at (10, 10, 200, 200), y pointing down.
func draw(_ ctx: CGContext, pixels: CGFloat) {
    // macOS icons leave a margin: the tile is 824 of 1024 points.
    let k = 824.0 / 200.0 * pixels / 1024.0, margin = 100.0 * pixels / 1024.0
    ctx.translateBy(x: 0, y: pixels); ctx.scaleBy(x: 1, y: -1)
    ctx.translateBy(x: margin, y: margin); ctx.scaleBy(x: k, y: k); ctx.translateBy(x: -10, y: -10)

    func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }
    func line(_ points: [(CGFloat, CGFloat)], _ hex: UInt32) {
        ctx.beginPath()
        ctx.move(to: CGPoint(x: points[0].0, y: points[0].1))
        for p in points.dropFirst() { ctx.addLine(to: CGPoint(x: p.0, y: p.1)) }
        ctx.setStrokeColor(color(hex)); ctx.setLineWidth(7); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    // Tile: dark blue, lighter at the top.
    ctx.saveGState()
    ctx.addPath(rounded(CGRect(x: 10, y: 10, width: 200, height: 200), 46)); ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(0x26364d), color(0x101826)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 10), end: CGPoint(x: 0, y: 210), options: [])
    ctx.restoreGState()

    // The window behind.
    ctx.addPath(rounded(CGRect(x: 64, y: 50, width: 116, height: 92), 14))
    ctx.setStrokeColor(color(0x8fa3bf)); ctx.setLineWidth(7); ctx.strokePath()

    // The window in front, with the two series lines from the tracks.
    let front = CGRect(x: 42, y: 74, width: 116, height: 92)
    ctx.addPath(rounded(front, 14)); ctx.setFillColor(color(0x16233a)); ctx.fillPath()
    ctx.saveGState()
    ctx.addPath(rounded(front.insetBy(dx: 3.5, dy: 3.5), 10.5)); ctx.clip()
    line([(40, 140), (66, 128), (82, 136), (104, 104), (122, 118), (162, 92)], 0x4d9bff)
    line([(40, 154), (70, 150), (92, 140), (114, 146), (136, 132), (162, 136)], 0xff8a4d)
    ctx.restoreGState()
    ctx.addPath(rounded(front, 14)); ctx.setStrokeColor(color(0xf2f5fa)); ctx.setLineWidth(7); ctx.strokePath()
    ctx.setFillColor(color(0xf2f5fa)); ctx.fillEllipse(in: CGRect(x: 53, y: 85, width: 8, height: 8))
}

func png(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    draw(g.cgContext, pixels: CGFloat(pixels))
    g.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("UTMWatch-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    try png(points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try tool.run(); tool.waitUntilExit()
guard tool.terminationStatus == 0 else { fatalError("iconutil failed") }
// A preview for the README and for checking the drawing by eye.
if CommandLine.arguments.count > 1 { try png(512).write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
print("Wrote Resources/AppIcon.icns")
