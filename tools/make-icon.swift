// Draws a "glass" app icon: a soft colour gradient with frosted, see-through layers on top.
// The same file is shared by hi-dad's Mac apps; each app has its own picture below.
//
//   swift tools/make-icon.swift <app> AppIcon.iconset
//   iconutil -c icns AppIcon.iconset -o AppIcon.icns
//
// <app> is one of: window-pane-relief, desktop-cat, copy-collector, shelfie, paperlight, jot, leftovers
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: make-icon.swift <app> <out.iconset>"); exit(1) }
let app = args[1], out = args[2]

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

/// Drawing helpers. Coordinates are in a 104 × 104 box (the icon's rounded square), y pointing down.
struct Pen {
    let ctx: CGContext
    let unit: CGFloat   // pixels per box unit

    func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
    }

    func shadow(_ on: Bool, blur: CGFloat = 6, dy: CGFloat = 2, alpha: CGFloat = 0.14) {
        // Shadow offsets ignore the flipped transform, so "down" is negative here.
        if on { ctx.setShadow(offset: CGSize(width: 0, height: -dy * unit), blur: blur * unit, color: hex(0x000000, alpha).cgColor) }
        else { ctx.setShadow(offset: .zero, blur: 0, color: nil) }
    }

    /// A frosted pane: translucent white fill with a bright edge.
    func glass(_ path: CGPath, fill: CGFloat, edge: CGFloat = 0.85, width: CGFloat = 1.2, lift: Bool = false) {
        ctx.saveGState()
        if lift { shadow(true) }
        ctx.addPath(path); ctx.setFillColor(hex(0xFFFFFF, fill).cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(path); ctx.setStrokeColor(hex(0xFFFFFF, edge).cgColor); ctx.setLineWidth(width); ctx.strokePath()
    }

    func fill(_ path: CGPath, _ c: NSColor, lift: Bool = false) {
        ctx.saveGState()
        if lift { shadow(true) }
        ctx.addPath(path); ctx.setFillColor(c.cgColor); ctx.fillPath()
        ctx.restoreGState()
    }

    func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2), transform: nil)
    }

    func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ c: NSColor, _ w: CGFloat) {
        ctx.move(to: CGPoint(x: x1, y: y1)); ctx.addLine(to: CGPoint(x: x2, y: y2))
        ctx.setStrokeColor(c.cgColor); ctx.setLineWidth(w); ctx.setLineCap(.round); ctx.strokePath()
    }

    func symbol(_ name: String, in r: CGRect, _ c: NSColor, lift: Bool = false) {
        let cfg = NSImage.SymbolConfiguration(pointSize: r.height * unit, weight: .regular)
            .applying(.init(paletteColors: [c]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        let sz = img.size, scale = min(r.width / (sz.width / unit), r.height / (sz.height / unit))
        let w = sz.width / unit * scale, h = sz.height / unit * scale
        ctx.saveGState()
        if lift { shadow(true) }
        img.draw(in: CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h), from: .zero,
                 operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        ctx.restoreGState()
    }

    func text(_ s: String, center: CGPoint, size: CGFloat, _ c: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: c]
        let str = NSAttributedString(string: s, attributes: attrs)
        let b = str.size()
        str.draw(at: CGPoint(x: center.x - b.width / 2, y: center.y - b.height / 2))
    }
}

struct Design { let top: UInt32; let bottom: UInt32; let draw: (Pen) -> Void }

let designs: [String: Design] = [
    // Two panes, the front one pinned on top.
    "window-pane-relief": Design(top: 0xA1C4FD, bottom: 0xB89AF5) { p in
        p.glass(p.rr(16, 20, 56, 46, 9), fill: 0.32)
        p.glass(p.rr(36, 42, 52, 42, 9), fill: 0.6, width: 1.4, lift: true)
        p.line(44, 51, 66, 51, hex(0xFFFFFF, 0.95), 2.2)
        p.fill(p.circle(78, 42, 7.5), hex(0xFFFFFF), lift: true)
        p.fill(p.circle(78, 42, 3.2), hex(0x8E7CF5))
    },
    // A cute cat face made of frosted glass.
    "desktop-cat": Design(top: 0xFFD08A, bottom: 0xFF8A4C) { p in
        func mirror(_ x: CGFloat) -> CGFloat { 104 - x }
        // Face and ears as one outline, so the glass has a single clean edge.
        var head: CGPath = CGPath(ellipseIn: CGRect(x: 20, y: 34, width: 64, height: 52), transform: nil)
        for flip in [false, true] {
            let x: (CGFloat) -> CGFloat = flip ? mirror : { $0 }
            let ear = CGMutablePath()
            ear.move(to: CGPoint(x: x(23), y: 54))
            ear.addLine(to: CGPoint(x: x(26), y: 22))
            ear.addQuadCurve(to: CGPoint(x: x(33), y: 20), control: CGPoint(x: x(27), y: 15))
            ear.addLine(to: CGPoint(x: x(50), y: 38))
            ear.closeSubpath()
            head = head.union(ear)
        }
        p.glass(head, fill: 0.5, edge: 0.95, width: 1.6)
        // Inner ears, a soft pink tint.
        for flip in [false, true] {
            let x: (CGFloat) -> CGFloat = flip ? mirror : { $0 }
            let ear = CGMutablePath()
            ear.move(to: CGPoint(x: x(29), y: 42))
            ear.addLine(to: CGPoint(x: x(30), y: 28))
            ear.addQuadCurve(to: CGPoint(x: x(34), y: 27), control: CGPoint(x: x(30.5), y: 24))
            ear.addLine(to: CGPoint(x: x(44), y: 38))
            ear.closeSubpath()
            p.fill(ear, hex(0xFFD2C8, 0.75))
        }
        let ink = hex(0xB5470F, 0.85)
        // Eyes with a glint.
        for x in [CGFloat(39), 65] {
            p.fill(CGPath(ellipseIn: CGRect(x: x - 4.4, y: 54, width: 8.8, height: 10.5), transform: nil), ink)
            p.fill(p.circle(x + 1.5, 57, 1.8), hex(0xFFFFFF, 0.95))
        }
        // Cheeks.
        for x in [CGFloat(30), 74] {
            p.fill(CGPath(ellipseIn: CGRect(x: x - 5, y: 65, width: 10, height: 5), transform: nil), hex(0xFF8F7A, 0.35))
        }
        // Nose and mouth.
        let nose = CGMutablePath()
        nose.move(to: CGPoint(x: 48.8, y: 65.5)); nose.addLine(to: CGPoint(x: 55.2, y: 65.5))
        nose.addQuadCurve(to: CGPoint(x: 52, y: 69.4), control: CGPoint(x: 54.8, y: 68))
        nose.addQuadCurve(to: CGPoint(x: 48.8, y: 65.5), control: CGPoint(x: 49.2, y: 68))
        p.fill(nose, hex(0xF06A5A, 0.9))
        p.ctx.move(to: CGPoint(x: 52, y: 69.2)); p.ctx.addLine(to: CGPoint(x: 52, y: 71.2))
        p.ctx.move(to: CGPoint(x: 46.8, y: 70.8)); p.ctx.addQuadCurve(to: CGPoint(x: 52, y: 71.2), control: CGPoint(x: 49, y: 74.2))
        p.ctx.addQuadCurve(to: CGPoint(x: 57.2, y: 70.8), control: CGPoint(x: 55, y: 74.2))
        p.ctx.setStrokeColor(ink.withAlphaComponent(0.7).cgColor); p.ctx.setLineWidth(1.3)
        p.ctx.setLineCap(.round); p.ctx.setLineJoin(.round); p.ctx.strokePath()
        // Whiskers, white like the glass edge.
        for (dy, endDy) in [(CGFloat(-2), CGFloat(-6)), (0.5, 0.5), (3, 7)] {
            p.line(34, 68 + dy, 10, 68 + endDy, hex(0xFFFFFF, 0.9), 1.2)
            p.line(70, 68 + dy, 94, 68 + endDy, hex(0xFFFFFF, 0.9), 1.2)
        }
    },
    // A pile of copied cards with a count badge.
    "copy-collector": Design(top: 0xA8F0C6, bottom: 0x3FBF9B) { p in
        p.glass(p.rr(30, 16, 52, 40, 8), fill: 0.22, edge: 0.6)
        p.glass(p.rr(24, 28, 56, 42, 8), fill: 0.38, edge: 0.75)
        p.glass(p.rr(18, 42, 60, 44, 9), fill: 0.7, width: 1.4, lift: true)
        let ink = hex(0x23997A, 0.55)
        p.line(27, 55, 62, 55, ink, 3); p.line(27, 63, 56, 63, ink, 3); p.line(27, 71, 48, 71, ink, 3)
        p.fill(p.circle(79, 44, 11), hex(0xFFFFFF), lift: true)
        p.text("3", center: CGPoint(x: 79, y: 44), size: 14, hex(0x1F8F70))
    },
    // Stacked screenshots, the front one with a little landscape.
    "shelfie": Design(top: 0x7FE0FF, bottom: 0x3B82F6) { p in
        p.ctx.saveGState()
        p.ctx.translateBy(x: 50, y: 44); p.ctx.rotate(by: -0.17); p.ctx.translateBy(x: -50, y: -44)
        p.glass(p.rr(22, 22, 56, 42, 7), fill: 0.3, edge: 0.7)
        p.ctx.restoreGState()
        p.glass(p.rr(26, 38, 60, 46, 8), fill: 0.7, width: 1.4, lift: true)
        p.fill(p.circle(41, 51, 5), hex(0xFFC93D))
        let m = CGMutablePath()
        m.move(to: CGPoint(x: 31, y: 79)); m.addLine(to: CGPoint(x: 48, y: 60)); m.addLine(to: CGPoint(x: 58, y: 70))
        m.addLine(to: CGPoint(x: 66, y: 62)); m.addLine(to: CGPoint(x: 81, y: 79)); m.closeSubpath()
        p.fill(m, hex(0x2563EB, 0.55))
    },
    // A frosted page in front of a warm sun.
    "paperlight": Design(top: 0xFFE0CC, bottom: 0xF49C8C) { p in
        p.fill(p.circle(72, 32, 17), hex(0xFFE59A))
        p.glass(p.rr(24, 18, 50, 70, 8), fill: 0.6, width: 1.4, lift: true)
        let ink = hex(0xD9604E, 0.45)
        for (i, len) in [34, 28, 32, 22, 26].enumerated() {
            let y = CGFloat(34 + i * 9)
            p.line(32, y, 32 + CGFloat(len), y, ink, 2.6)
        }
    },
    // A takeout box with chopsticks.
    "leftovers": Design(top: 0xFF9E8F, bottom: 0xD9383F) { p in
        // Chopsticks behind the box, so the glass frosts over them.
        p.line(56, 54, 84, 14, hex(0xFFE2B8), 3.2)
        p.line(63, 56, 92, 20, hex(0xFFE2B8), 3.2)
        // Wire handle.
        p.ctx.move(to: CGPoint(x: 36, y: 38)); p.ctx.addQuadCurve(to: CGPoint(x: 68, y: 38), control: CGPoint(x: 52, y: 12))
        p.ctx.setStrokeColor(hex(0xFFFFFF, 0.9).cgColor); p.ctx.setLineWidth(2); p.ctx.strokePath()
        // Box: tapered body with a folded top band.
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 24, y: 42)); body.addLine(to: CGPoint(x: 80, y: 42))
        body.addLine(to: CGPoint(x: 72, y: 87)); body.addLine(to: CGPoint(x: 32, y: 87)); body.closeSubpath()
        p.glass(body, fill: 0.55, edge: 0.95, width: 1.5)
        let band = CGMutablePath()
        band.move(to: CGPoint(x: 20, y: 34)); band.addLine(to: CGPoint(x: 84, y: 34))
        band.addLine(to: CGPoint(x: 80, y: 46)); band.addLine(to: CGPoint(x: 24, y: 46)); band.closeSubpath()
        p.glass(band, fill: 0.75, edge: 0.95, width: 1.5)
        // A little red seal on the front.
        p.ctx.addPath(p.circle(52, 65, 7.5)); p.ctx.setStrokeColor(hex(0xC9303A, 0.7).cgColor); p.ctx.setLineWidth(1.8); p.ctx.strokePath()
        p.fill(p.circle(52, 65, 3), hex(0xC9303A, 0.7))
    },
    // A note with bullet points.
    "jot": Design(top: 0xFFC2E6, bottom: 0xD46BD8) { p in
        p.glass(p.rr(18, 18, 68, 68, 12), fill: 0.65, width: 1.4, lift: true)
        p.line(18, 31, 86, 31, hex(0xFFFFFF, 0.9), 1.2)
        let ink = hex(0xA63DB3, 0.85), soft = hex(0xA63DB3, 0.45)
        for (i, len) in [32, 26, 20].enumerated() {
            let y = CGFloat(45 + i * 13)
            p.fill(p.circle(31, y, 3.6), ink)
            p.line(40, y, 40 + CGFloat(len), y, soft, 3)
        }
    },
]

guard let d = designs[app] else { print("unknown app \(app); choose from \(designs.keys.sorted())"); exit(1) }
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    // Flip to y-down, then map the 104-unit box onto Apple's icon grid (the square is 80% of the canvas).
    ctx.translateBy(x: 0, y: s); ctx.scaleBy(x: 1, y: -1)
    let unit = s * 0.8 / 104
    ctx.translateBy(x: s * 0.1, y: s * 0.1); ctx.scaleBy(x: unit, y: unit)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    let p = Pen(ctx: ctx, unit: unit)

    let shape = p.rr(0, 0, 104, 104, 23)
    // Soft drop shadow under the whole icon, like Apple's.
    p.ctx.saveGState(); p.shadow(true, blur: 5, dy: 2, alpha: 0.22)
    ctx.addPath(shape); ctx.setFillColor(hex(d.bottom).cgColor); ctx.fillPath(); p.ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [hex(d.top).cgColor, hex(d.bottom).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 10, y: 0), end: CGPoint(x: 94, y: 104), options: [])
    // A gentle sheen across the top.
    let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [hex(0xFFFFFF, 0.28).cgColor, hex(0xFFFFFF, 0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 52, y: 0), end: CGPoint(x: 52, y: 52), options: [])
    d.draw(p)
    ctx.restoreGState()
    // A thin bright rim.
    ctx.addPath(p.rr(0.6, 0.6, 102.8, 102.8, 22.5)); ctx.setStrokeColor(hex(0xFFFFFF, 0.35).cgColor); ctx.setLineWidth(1.2); ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
