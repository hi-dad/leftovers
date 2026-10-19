import AppKit
import Combine
import ServiceManagement
import SwiftUI

@main
enum LeftoversMain {
    static func main() {
        if CommandLine.arguments.contains("--once") { Monitor.shared.printOnce(); return }
        if let i = CommandLine.arguments.firstIndex(of: "--render-demo"), i + 1 < CommandLine.arguments.count {
            let args = CommandLine.arguments
            let scenario = args.firstIndex(of: "--scenario").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            DemoRender.run(to: args[i + 1], settings: args.contains("--settings"), scenario: scenario); return
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
    var dotLayer: CALayer?

    func applicationDidFinishLaunching(_ n: Notification) {
        let me = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0 != me }) {
            NSApp.terminate(nil); return
        }
        // First launch: open at login, so Leftovers is still watching after a restart (it can't catch anything
        // if it isn't running). Switchable in Settings. Only for the installed app, never a test build.
        if !UserDefaults.standard.bool(forKey: "setUpOpenAtLogin"), Bundle.main.bundlePath.hasPrefix("/Applications/") {
            UserDefaults.standard.set(true, forKey: "setUpOpenAtLogin")
            try? SMAppService.mainApp.register()
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
                if app?.executableURL?.lastPathComponent.hasPrefix("qemu-system") == true { Monitor.shared.lastAndroidUse = Date() }
            }
        }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.iphonesimulator" {
            m.lastSimulatorUse = Date()
        }
        m.start()
        // For screenshots in testing: `open Leftovers.app --args -openOnLaunch YES`.
        if UserDefaults.standard.bool(forKey: "openOnLaunch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                UIState.shared.showSettings = UserDefaults.standard.bool(forKey: "openSettings")
                self.openDrop()
            }
        }
    }

    /// The takeout-box icon; a small orange dot when something needs a look, red when something is stuck.
    func updateIcon(_ items: [Item]) {
        guard let button = item.button else { return }
        let worst = items.map(\.verdict.level).filter { $0 >= .warn }.max()
        button.image = MenuBarIcon.image
        button.imagePosition = .imageOnly
        button.title = ""
        button.wantsLayer = true
        if dotLayer == nil, let layer = button.layer {
            let dot = CALayer()
            dot.cornerRadius = MenuBarIcon.dotSize / 2
            layer.addSublayer(dot)
            dotLayer = dot
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dotLayer?.frame = MenuBarIcon.dotFrame(in: button.bounds, flipped: button.layer?.isGeometryFlipped == true || button.isFlipped)
        dotLayer?.backgroundColor = (worst == .alarm ? NSColor.systemRed : NSColor.systemOrange).cgColor
        dotLayer?.isHidden = worst == nil
        CATransaction.commit()
        button.setAccessibilityLabel(worst == nil ? "Leftovers: all clear" : "Leftovers: something needs a look")
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
        // Never taller than the screen: the list inside scrolls instead.
        let maxHeight = (bw.screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 900) - 24
        let height = min(ceil(h.fittingSize.height), maxHeight)
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
