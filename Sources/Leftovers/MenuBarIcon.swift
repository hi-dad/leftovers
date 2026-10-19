import AppKit

/// The menu bar icon: a takeout box with chopsticks (leftovers!), drawn as a template image so macOS colors it
/// for light and dark menu bars. A small orange or red dot in the bottom-right corner means something needs a look.
enum MenuBarIcon {
    /// 22×18 pt: the box fills the left 18 pt; the right edge leaves room for the dot.
    static let image: NSImage = {
        let img = NSImage(size: NSSize(width: 22, height: 18), flipped: true) { _ in
            let p = NSBezierPath()
            p.lineWidth = 1.35
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            let top: CGFloat = 7.5
            // Box: wider at the top, narrower at the bottom.
            p.move(to: NSPoint(x: 3.2, y: top)); p.line(to: NSPoint(x: 5.2, y: 16.2))
            p.line(to: NSPoint(x: 12.8, y: 16.2)); p.line(to: NSPoint(x: 14.8, y: top)); p.close()
            // Folded top flaps.
            p.move(to: NSPoint(x: 3.2, y: top)); p.line(to: NSPoint(x: 5.6, y: top - 2.6))
            p.line(to: NSPoint(x: 9, y: top - 1.2)); p.line(to: NSPoint(x: 12.4, y: top - 2.6))
            p.line(to: NSPoint(x: 14.8, y: top))
            // Chopsticks.
            p.move(to: NSPoint(x: 10.6, y: 5.6)); p.line(to: NSPoint(x: 15.6, y: 0.8))
            p.move(to: NSPoint(x: 12.0, y: 6.0)); p.line(to: NSPoint(x: 17.0, y: 2.0))
            NSColor.black.setStroke()
            p.stroke()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Leftovers"
        return img
    }()

    static let dotSize: CGFloat = 6.2

    /// Where the dot goes inside the status item button (bottom-right of the icon).
    /// `flipped`: whether the button's layer counts y from the top (the menu bar's does).
    static func dotFrame(in bounds: NSRect, flipped: Bool) -> NSRect {
        let left = bounds.midX - image.size.width / 2
        let bottomGap: CGFloat = 0.2
        let y = flipped ? bounds.midY + image.size.height / 2 - bottomGap - dotSize
                        : bounds.midY - image.size.height / 2 + bottomGap
        return NSRect(x: left + 21.6 - dotSize, y: y, width: dotSize, height: dotSize)
    }
}
