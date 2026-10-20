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

    /// Thick "liquid glass": a gradient body, a soft shine top-left, a bright top rim fading
    /// toward the bottom, and a faint glow along the bottom edge where light gathers.
    func liquid(_ path: CGPath, tint: UInt32 = 0xFFFFFF, top: CGFloat = 0.78, bottom: CGFloat = 0.28, lift: Bool = true, rim: CGFloat = 1.6) {
        let b = path.boundingBox
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        func grad(_ cs: [NSColor], _ locs: [CGFloat]) -> CGGradient {
            CGGradient(colorsSpace: space, colors: cs.map(\.cgColor) as CFArray, locations: locs)!
        }
        if lift {
            ctx.saveGState(); shadow(true, blur: 4, dy: 2, alpha: 0.16)
            ctx.addPath(path); ctx.setFillColor(hex(tint, 0.2).cgColor); ctx.fillPath(); ctx.restoreGState()
        }
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        ctx.drawLinearGradient(grad([hex(tint, top), hex(tint, bottom)], [0, 1]),
                               start: CGPoint(x: b.minX, y: b.minY), end: CGPoint(x: b.maxX * 0.3 + b.minX * 0.7, y: b.maxY), options: [])
        ctx.drawLinearGradient(grad([hex(0xFFFFFF, 0), hex(0xFFFFFF, 0.38)], [0, 1]),
                               start: CGPoint(x: b.midX, y: b.maxY - b.height * 0.22), end: CGPoint(x: b.midX, y: b.maxY), options: [])
        ctx.addEllipse(in: CGRect(x: b.minX + b.width * 0.06, y: b.minY + b.height * 0.04, width: b.width * 0.5, height: b.height * 0.16))
        ctx.setFillColor(hex(0xFFFFFF, 0.32).cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState(); ctx.addPath(path); ctx.setLineWidth(rim); ctx.setLineJoin(.round)
        ctx.replacePathWithStrokedPath(); ctx.clip()
        ctx.drawLinearGradient(grad([hex(0xFFFFFF, 1), hex(0xFFFFFF, 0.35)], [0, 1]),
                               start: CGPoint(x: b.minX, y: b.minY), end: CGPoint(x: b.maxX, y: b.maxY), options: [])
        ctx.restoreGState()
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

func takeout(_ p: Pen, chop: UInt32, front: Bool, flaps: Bool, steam: Bool) {
    func sticks() {
        p.line(56, 56, 84, 14, hex(chop, 0.95), 3.4)
        p.line(63, 58, 92, 20, hex(chop, 0.95), 3.4)
    }
    if !front { sticks() }
    if steam {
        for x in [CGFloat(40), 52, 64] {
            p.ctx.move(to: CGPoint(x: x, y: 28)); p.ctx.addCurve(to: CGPoint(x: x, y: 12), control1: CGPoint(x: x - 5, y: 23), control2: CGPoint(x: x + 5, y: 17))
            p.ctx.setStrokeColor(hex(0xFFFFFF, 0.85).cgColor); p.ctx.setLineWidth(2); p.ctx.setLineCap(.round); p.ctx.strokePath()
        }
    } else {
        p.ctx.move(to: CGPoint(x: 36, y: 38)); p.ctx.addQuadCurve(to: CGPoint(x: 68, y: 38), control: CGPoint(x: 52, y: 12))
        p.ctx.setStrokeColor(hex(0xFFFFFF, 0.95).cgColor); p.ctx.setLineWidth(2.2); p.ctx.strokePath()
    }
    let body = CGMutablePath()
    body.move(to: CGPoint(x: 24, y: 44)); body.addLine(to: CGPoint(x: 80, y: 44))
    body.addLine(to: CGPoint(x: 71, y: 88)); body.addLine(to: CGPoint(x: 33, y: 88)); body.closeSubpath()
    p.liquid(body, top: 0.7, bottom: 0.3)
    if flaps {
        for (a, b, c) in [((22.0, 44.0), (34.0, 30.0), (52.0, 44.0)), ((52.0, 44.0), (70.0, 30.0), (82.0, 44.0))] {
            let f = CGMutablePath(); f.move(to: CGPoint(x: a.0, y: a.1)); f.addLine(to: CGPoint(x: b.0, y: b.1)); f.addLine(to: CGPoint(x: c.0, y: c.1)); f.closeSubpath()
            p.liquid(f, top: 0.85, bottom: 0.5, lift: false, rim: 1.4)
        }
    } else {
        let band = CGMutablePath()
        band.move(to: CGPoint(x: 20, y: 35)); band.addLine(to: CGPoint(x: 84, y: 35))
        band.addLine(to: CGPoint(x: 80, y: 47)); band.addLine(to: CGPoint(x: 24, y: 47)); band.closeSubpath()
        p.liquid(band, top: 0.9, bottom: 0.55, rim: 1.4)
    }
    // Soft folds down the front of the box.
    p.line(44, 52, 46, 84, hex(0xFFFFFF, 0.45), 1); p.line(60, 52, 58, 84, hex(0xFFFFFF, 0.45), 1)
    if front { sticks() }
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
    // A glass bubble with a count, like the menu bar icon.
    "copy-collector": Design(top: 0xA8F0C6, bottom: 0x3FBF9B) { p in
        p.liquid(p.circle(60, 44, 24), top: 0.45, bottom: 0.15, lift: false)
        p.liquid(p.circle(48, 58, 30))
        p.text("3", center: CGPoint(x: 48, y: 58), size: 34, hex(0x1F8F70, 0.85))
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
    // An open book in front of a warm sun.
    "paperlight": Design(top: 0xFFE0CC, bottom: 0xF49C8C) { p in
        p.fill(p.circle(52, 30, 15), hex(0xFFE59A))
        func bez(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint, _ t: CGFloat) -> CGPoint {
            let u = 1 - t
            return CGPoint(x: u*u*u*a.x + 3*u*u*t*b.x + 3*u*t*t*c.x + t*t*t*d.x,
                           y: u*u*u*a.y + 3*u*u*t*b.y + 3*u*t*t*c.y + t*t*t*d.y)
        }
        for flip in [false, true] {
            let x: (CGFloat) -> CGFloat = flip ? { 104 - $0 } : { $0 }
            let top = [CGPoint(x: 52, y: 40), CGPoint(x: x(42), y: 32), CGPoint(x: x(26), y: 32), CGPoint(x: x(14), y: 38)]
            let bottom = [CGPoint(x: 52, y: 86), CGPoint(x: x(42), y: 78), CGPoint(x: x(26), y: 76), CGPoint(x: x(14), y: 82)]
            let page = CGMutablePath()
            page.move(to: top[0]); page.addCurve(to: top[3], control1: top[1], control2: top[2])
            page.addLine(to: bottom[3]); page.addCurve(to: bottom[0], control1: bottom[2], control2: bottom[1])
            page.closeSubpath()
            p.liquid(page, top: 0.8, bottom: 0.35)
            // Text lines that bend with the page: blend between its top and bottom edges.
            let ink = hex(0xD9604E, 0.42)
            for (i, f) in [CGFloat(0.26), 0.42, 0.58].enumerated() {
                let end: CGFloat = i == 2 ? 0.62 : 0.84
                let line = CGMutablePath()
                for k in 0...24 {
                    let t = 0.14 + (end - 0.14) * CGFloat(k) / 24
                    let pt = bez(top[0], top[1], top[2], top[3], t), pb = bez(bottom[0], bottom[1], bottom[2], bottom[3], t)
                    let q = CGPoint(x: pt.x + (pb.x - pt.x) * f, y: pt.y + (pb.y - pt.y) * f)
                    if k == 0 { line.move(to: q) } else { line.addLine(to: q) }
                }
                p.ctx.addPath(line); p.ctx.setStrokeColor(ink.cgColor); p.ctx.setLineWidth(2.2)
                p.ctx.setLineCap(.round); p.ctx.setLineJoin(.round); p.ctx.strokePath()
            }
        }
    },
    // A takeout box with chopsticks.
    "leftovers": Design(top: 0xFF9E8F, bottom: 0xD9383F) { p in takeout(p, chop: 0xFFFFFF, front: true, flaps: false, steam: false) },
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
