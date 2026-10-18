import AppKit
import Combine
import SwiftUI

@main
enum LeftoversMain {
    static func main() {
        if CommandLine.arguments.contains("--once") { Monitor.shared.printOnce(); return }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class DropPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let m = Monitor.shared
    var item: NSStatusItem!
    var drop: DropPanel?
    var dropHost: NSView?
    var lastClose = Date.distantPast
    var watchers: Set<AnyCancellable> = []
    var clickMonitor: Any?

    func applicationDidFinishLaunching(_ n: Notification) {
        let me = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0 != me }) {
            NSApp.terminate(nil); return
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggleDrop)
        m.$items.sink { [weak self] items in self?.updateIcon(items) }.store(in: &watchers)
        m.start()
        // For screenshots in testing: `open Leftovers.app --args -openOnLaunch YES`.
        if UserDefaults.standard.bool(forKey: "openOnLaunch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.openDrop() }
        }
    }

    func updateIcon(_ items: [Item]) {
        let leftovers = items.filter { $0.kind == .leftover }.count
        let img = NSImage(systemSymbolName: leftovers > 0 ? "leaf.fill" : "leaf", accessibilityDescription: "Leftovers")
        img?.isTemplate = true
        item.button?.image = img
        item.button?.title = leftovers > 0 ? " \(leftovers)" : ""
        item.button?.imagePosition = .imageLeading
    }

    @objc func toggleDrop() {
        if drop?.isVisible == true { closeDrop(); return }
        // The same click on the icon may already have closed it a moment ago; then it meant "close".
        if Date().timeIntervalSince(lastClose) < 0.4 { return }
        openDrop()
    }

    // Our own panel (not NSPopover) so its top edge stays pinned under the icon while it resizes.
    func openDrop() {
        if drop == nil {
            let p = DropPanel(contentRect: NSRect(x: 0, y: 0, width: menuWidth, height: 200),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
            p.level = .popUpMenu
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isReleasedWhenClosed = false
            let fx = NSVisualEffectView()
            fx.material = .popover; fx.state = .active; fx.blendingMode = .behindWindow
            fx.wantsLayer = true; fx.layer?.cornerRadius = 12; fx.layer?.masksToBounds = true
            let h = NSHostingView(rootView: MenuView().environmentObject(m))
            dropHost = h
            m.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.fitDrop() } }.store(in: &watchers)
            h.autoresizingMask = [.width, .height]
            fx.addSubview(h)
            p.contentView = fx
            h.frame = fx.bounds
            p.delegate = self
            drop = p
        }
        m.scan()   // fresh numbers every time it opens
        fitDrop()
        drop?.makeKeyAndOrderFront(nil)
        item.button?.highlight(true)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closeDrop()
        }
    }

    func closeDrop() {
        if drop?.isVisible == true { lastClose = Date() }
        drop?.orderOut(nil)
        item.button?.highlight(false)
        if let c = clickMonitor { NSEvent.removeMonitor(c); clickMonitor = nil }
    }

    func fitDrop() {
        guard let h = dropHost, let p = drop, let b = item.button, let bw = b.window else { return }
        let height = ceil(h.fittingSize.height)
        guard height > 0 else { return }
        let icon = bw.convertToScreen(b.convert(b.bounds, to: nil))
        let screen = bw.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let x = min(max(icon.midX - menuWidth / 2, screen.minX + 8), screen.maxX - menuWidth - 8)
        p.setFrame(NSRect(x: x, y: icon.minY - 6 - height, width: menuWidth, height: height), display: true)
    }

    func windowDidResignKey(_ n: Notification) {
        guard (n.object as? NSPanel) === drop else { return }
        if let b = item.button, let bw = b.window,
           bw.convertToScreen(b.convert(b.bounds, to: nil)).contains(NSEvent.mouseLocation) { return }
        closeDrop()
    }
}
