import AppKit
import Combine
import SwiftUI

@main
enum LeftoversMain {
    static func main() {
        if CommandLine.arguments.contains("--once") { Monitor.shared.printOnce(); return }
        if let i = CommandLine.arguments.firstIndex(of: "--render-demo"), i + 1 < CommandLine.arguments.count {
            DemoRender.run(to: CommandLine.arguments[i + 1], settings: CommandLine.arguments.contains("--settings")); return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--stop"), i + 1 < CommandLine.arguments.count {
            Monitor.shared.stopOnce(matching: CommandLine.arguments[i + 1]); return
        }
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
        Notifier.shared.onReview = { [weak self] in
            if self?.drop?.isVisible != true { self?.openDrop() }
        }
        Notifier.shared.start()
        // Using the Simulator app counts as using the simulators.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { n in
                let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if app?.bundleIdentifier == "com.apple.iphonesimulator" { Monitor.shared.lastSimulatorUse = Date() }
                if app?.bundleIdentifier == "com.google.Chrome" { Monitor.shared.lastChromeUse = Date() }
                if app?.executableURL?.lastPathComponent.hasPrefix("qemu-system") == true { Monitor.shared.lastAndroidUse = Date() }
            }
        }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.iphonesimulator" {
            m.lastSimulatorUse = Date()
        }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.google.Chrome" { m.lastChromeUse = Date() }
        m.start()
        // For screenshots in testing: `open Leftovers.app --args -openOnLaunch YES`.
        if UserDefaults.standard.bool(forKey: "openOnLaunch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                UIState.shared.showSettings = UserDefaults.standard.bool(forKey: "openSettings")
                self.openDrop()
            }
        }
    }

    /// Plain leaf when all is well; a count beside it (orange, or red if something looks stuck) when not.
    func updateIcon(_ items: [Item]) {
        let flagged = items.filter { $0.verdict.level >= .warn }
        let worst = flagged.map(\.verdict.level).max() ?? .none
        let img = NSImage(systemSymbolName: flagged.isEmpty ? "leaf" : "leaf.fill", accessibilityDescription: "Leftovers")
        img?.isTemplate = true
        item.button?.image = img
        item.button?.imagePosition = .imageLeading
        if flagged.isEmpty {
            item.button?.attributedTitle = NSAttributedString(string: "")
        } else {
            let color: NSColor = worst == .alarm ? .systemRed : .systemOrange
            item.button?.attributedTitle = NSAttributedString(string: " \(flagged.count)", attributes: [
                .foregroundColor: color, .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)])
        }
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
            m.objectWillChange.merge(with: UIState.shared.objectWillChange)
                .sink { [weak self] _ in DispatchQueue.main.async { self?.fitDrop() } }.store(in: &watchers)
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
        UIState.shared.showSettings = false
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
