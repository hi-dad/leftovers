import AppKit
import SwiftUI

/// `Leftovers --render-demo <file.png>` (add `--settings` for the settings screen): draws the dropdown with example rows, for the README.
/// Works offscreen (no menu bar or display needed).
enum DemoRender {
    static func run(to path: String, settings: Bool = false) {
        UIState.shared.showSettings = settings
        let now = Date()
        func item(_ kind: ItemKind, _ title: String, _ detail: String, hours: Double, perHour: Double,
                  verdict: Verdict, project: String? = nil, output: Double? = nil, ports: [UInt16] = []) -> Item {
            var i = Item(id: title, kind: kind, title: title, detail: detail, command: "", project: project, pids: [],
                         started: now.addingTimeInterval(-hours * 3600), batteryPerHour: perHour, ports: ports,
                         lastOutput: output.map { now.addingTimeInterval(-$0 * 3600) })
            i.verdict = verdict
            return i
        }
        let demo = [
            item(.leftover, "Video encoding (ffmpeg)", "Left by “QuickNote ad video” · running 2 days · started by Script build.sh",
                 hours: 48, perHour: 8, verdict: Verdict(level: .alarm, tag: "Looks stuck"), project: "scratch files", output: 47),
            item(.simulator, "iPhone 17 (iOS 27.0)", "Running StoryboardAR · booted 31 h ago",
                 hours: 31, perHour: 4, verdict: Verdict(level: .warn, tag: "Unused 30 h")),
            item(.appStarted, "Dev server (Vite) on port 5173", "Running for 3 h",
                 hours: 3, perHour: 0.2, verdict: Verdict(level: .info, tag: "Idle 2 h"), project: "pokemon-silverwind", ports: [5173]),
        ]
        Monitor.shared.showDemo(demo)
        let view = MenuView().environmentObject(Monitor.shared)
            .background(Color(nsColor: NSColor(white: 0.17, alpha: 1)))
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("wrote", path, host.bounds.size)
    }
}
