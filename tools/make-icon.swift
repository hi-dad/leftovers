// Draws the app icon (assets/AppIcon.icns): a white leaf on a green rounded square.
// Run: swift tools/make-icon.swift && iconutil -c icns assets/AppIcon.iconset -o assets/AppIcon.icns
import AppKit

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: 824/1024 body with rounded corners.
    let inset = s * 100 / 1024, body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(starting: NSColor(red: 0.36, green: 0.78, blue: 0.45, alpha: 1),
               ending: NSColor(red: 0.10, green: 0.50, blue: 0.33, alpha: 1))!.draw(in: path, angle: -90)
    let cfg = NSImage.SymbolConfiguration(pointSize: body.width * 0.5, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let leaf = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let sz = leaf.size
        leaf.draw(in: NSRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2, width: sz.width, height: sz.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = "assets/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: URL(fileURLWithPath: "\(dir)/icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: URL(fileURLWithPath: "\(dir)/icon_\(base)x\(base)@2x.png"))
}
try! draw(1024).write(to: URL(fileURLWithPath: "assets/icon-1024.png"))
