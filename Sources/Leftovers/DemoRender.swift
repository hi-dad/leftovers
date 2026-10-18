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
        var stuck = item(.leftover, "Video encoding (ffmpeg)", "", hours: 48, perHour: 8,
                         verdict: Verdict(level: .alarm, tag: "Looks stuck"), project: "scratch files", output: 47)
        stuck.noun = "Video export"; stuck.session = "QuickNote ad video"; stuck.starter = "Script build.sh"
        stuck.folder = NSHomeDirectory() + "/Desktop/claude/quick-ad"
        stuck.command = "ffmpeg -i 67.mov -i 66.mov -filter_complex … -c:v libx264 quicknote-ad.mp4"
        stuck.cpuPercent = 250
        var loop = item(.leftover, "Python one-liner", "", hours: 2, perHour: 3,
                        verdict: Verdict(level: .warn, tag: "Forgotten"), project: "zom-zom")
        loop.noun = "Python script"
        var sim = item(.simulator, "iPhone 17 (iOS 27.0)", "", hours: 31, perHour: 4,
                       verdict: Verdict(level: .warn, tag: "Unused 30 h"))
        sim.noun = "iPhone simulator"; sim.apps = ["StoryboardAR"]
        var site = item(.appStarted, "Dev server (Vite) on port 5173", "", hours: 3, perHour: 0.2,
                        verdict: Verdict(level: .info, tag: "Idle 2 h"), project: "pokemon-silverwind", ports: [5173])
        site.noun = "Test website"
        let demo = [stuck, loop, sim, site]
        UIState.shared.expandFirst = false
        UIState.shared.tallForPicture = true
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
