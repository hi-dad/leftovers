import AppKit
import SwiftUI

// Custom takeout-box menu bar icons, drawn in an 18×18 grid (like SF Symbols at menu bar size).
typealias Draw = (inout Path) -> Void

func pail(_ p: inout Path, top: CGFloat = 6.5) {
    // Box body: wider at the top, narrower at the bottom.
    p.move(to: CGPoint(x: 3.2, y: top)); p.addLine(to: CGPoint(x: 5.2, y: 16.2))
    p.addLine(to: CGPoint(x: 12.8, y: 16.2)); p.addLine(to: CGPoint(x: 14.8, y: top)); p.closeSubpath()
    // Folded top flaps.
    p.move(to: CGPoint(x: 3.2, y: top)); p.addLine(to: CGPoint(x: 5.6, y: top - 2.6))
    p.addLine(to: CGPoint(x: 9, y: top - 1.2)); p.addLine(to: CGPoint(x: 12.4, y: top - 2.6))
    p.addLine(to: CGPoint(x: 14.8, y: top))
}
func handle(_ p: inout Path, top: CGFloat = 6.5) {
    // A narrow wire loop rising from the two flap tips.
    p.move(to: CGPoint(x: 5.6, y: top - 2.6))
    p.addCurve(to: CGPoint(x: 12.4, y: top - 2.6), control1: CGPoint(x: 5.9, y: top - 8.6), control2: CGPoint(x: 12.1, y: top - 8.6))
}
func steam(_ p: inout Path, xs: [CGFloat], y0: CGFloat, y1: CGFloat) {
    for x in xs {
        p.move(to: CGPoint(x: x, y: y0))
        p.addCurve(to: CGPoint(x: x, y: y1), control1: CGPoint(x: x - 1.4, y: (y0 * 2 + y1) / 3), control2: CGPoint(x: x + 1.4, y: (y0 + y1 * 2) / 3))
    }
}

struct Design { let name: String; let idea: String; let draw: Draw }
let designs: [Design] = [
    Design(name: "1 · Classic takeout box", idea: "The folded box with a wire handle", draw: { p in pail(&p, top: 8.6); handle(&p, top: 8.6) }),
    Design(name: "2 · Steaming takeout", idea: "Still warm = still running", draw: { p in
        pail(&p, top: 9.5); steam(&p, xs: [6.5, 9, 11.5], y0: 5.6, y1: 0.8) }),
    Design(name: "3 · Takeout + chopsticks", idea: "Instantly reads as leftovers", draw: { p in
        pail(&p, top: 7.5)
        p.move(to: CGPoint(x: 10.6, y: 5.6)); p.addLine(to: CGPoint(x: 15.6, y: 0.8))
        p.move(to: CGPoint(x: 12.0, y: 6.0)); p.addLine(to: CGPoint(x: 17.0, y: 2.0)) }),
    Design(name: "4 · Leftovers container", idea: "Fridge tub with a lid and steam", draw: { p in
        p.addRoundedRect(in: CGRect(x: 2.4, y: 9.2, width: 13.2, height: 7), cornerSize: CGSize(width: 2, height: 2))
        p.addRoundedRect(in: CGRect(x: 1.4, y: 7.0, width: 15.2, height: 2.2), cornerSize: CGSize(width: 1, height: 1))
        steam(&p, xs: [6.3, 9, 11.7], y0: 5.4, y1: 1.0) }),
    Design(name: "5 · Takeout box with bolt", idea: "Leftovers + power use", draw: { p in
        pail(&p, top: 8.6); handle(&p, top: 8.6)
        p.move(to: CGPoint(x: 9.8, y: 9.8)); p.addLine(to: CGPoint(x: 7.8, y: 12.7)); p.addLine(to: CGPoint(x: 9.6, y: 12.7))
        p.addLine(to: CGPoint(x: 8.5, y: 15.2)); p.addLine(to: CGPoint(x: 10.5, y: 12.0)); p.addLine(to: CGPoint(x: 8.7, y: 12.0))
        p.closeSubpath() }),
    Design(name: "6 · Takeout with a little face", idea: "Friendly, mascot-like", draw: { p in
        pail(&p, top: 8.6); handle(&p, top: 8.6)
        p.addEllipse(in: CGRect(x: 6.6, y: 10.8, width: 1.3, height: 1.3)); p.addEllipse(in: CGRect(x: 10.1, y: 10.8, width: 1.3, height: 1.3))
        p.move(to: CGPoint(x: 7.4, y: 13.4)); p.addQuadCurve(to: CGPoint(x: 10.6, y: 13.4), control: CGPoint(x: 9, y: 15.0)) }),
]

enum Dot { case none, orange, red }

struct MenuIcon: View {
    let d: Design; let dot: Dot; let fg: Color; let size: CGFloat
    var body: some View {
        Canvas { ctx, sz in
            let k = sz.height / 18
            var path = Path(); d.draw(&path)
            let scaled = path.applying(CGAffineTransform(scaleX: k, y: k))
            ctx.stroke(scaled, with: .color(fg), style: StrokeStyle(lineWidth: 1.35 * k, lineCap: .round, lineJoin: .round))
            if dot != .none {
                let r = 6.2 * k
                let c = CGRect(x: 21.6 * k - r, y: 17.8 * k - r, width: r, height: r)
                ctx.fill(Path(ellipseIn: c.insetBy(dx: -1.3 * k, dy: -1.3 * k)), with: .color(fg == .white ? Color(white: 0.13) : Color(white: 0.92)))
                ctx.fill(Path(ellipseIn: c), with: .color(dot == .red ? .red : .orange))
            }
        }
        .frame(width: size * 22 / 18, height: size)
    }
}

struct Bar: View {
    let d: Design; let dot: Dot; let dark: Bool
    var body: some View {
        MenuIcon(d: d, dot: dot, fg: dark ? .white : .black, size: 18)
            .frame(width: 34, height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: dark ? 0.13 : 0.92)))
    }
}

struct Sheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Takeout menu bar icons").font(.system(size: 22, weight: .bold))
            Text("Shown at real menu bar size on dark and light bars: all clear · orange dot (needs a look) · red dot (stuck)")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            ForEach(designs, id: \.name) { d in
                HStack(spacing: 18) {
                    MenuIcon(d: d, dot: .none, fg: .black, size: 54)
                        .padding(8).background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.name).font(.system(size: 15, weight: .semibold))
                        Text(d.idea).font(.system(size: 12)).foregroundStyle(.secondary)
                    }.frame(width: 210, alignment: .leading)
                    HStack(spacing: 6) { ForEach([Dot.none, .orange, .red], id: \.self) { Bar(d: d, dot: $0, dark: true) } }
                    HStack(spacing: 6) { ForEach([Dot.none, .orange, .red], id: \.self) { Bar(d: d, dot: $0, dark: false) } }
                }
            }
        }
        .padding(24)
        .background(Color(white: 0.97))
        .environment(\.colorScheme, .light)
    }
}

let host = NSHostingView(rootView: Sheet())
host.frame = NSRect(origin: .zero, size: host.fittingSize)
host.layoutSubtreeIfNeeded()
let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
host.cacheDisplay(in: host.bounds, to: rep)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("ok")
