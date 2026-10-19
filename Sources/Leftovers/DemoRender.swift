import AppKit
import SwiftUI

/// `Leftovers --render-demo <file.png> [--settings | --scenario <name>]`: draws the dropdown with example rows,
/// for the README and for previewing every kind of row. Scenarios: clear, quiet, leftovers, devices, claude, system.
/// Works offscreen (no menu bar or display needed).
enum DemoRender {
    static func run(to path: String, settings: Bool = false, scenario: String? = nil) {
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
        var demo = [stuck, loop, sim, site]
        UIState.shared.expandID = nil
        if let scenario {
            let (rows, expand) = examples(scenario, item: item, stuck: stuck, loop: loop, sim: sim, site: site)
            demo = rows
            UIState.shared.expandID = expand ? (scenario == "claude" ? "Claude app windows" : rows.first?.id) : nil
            if scenario == "chats" { UIState.shared.expandID = "9 chat helpers" }
        }
        UIState.shared.tallForPicture = true
        // Fill in the subheaders the way the live app does, from a made-up recent history.
        let simUse: TimeInterval = scenario == "quiet" ? 5 * 60 : 30 * 3600
        let ctx = RuleContext(now: now, onBattery: true, lastSimulatorUse: now.addingTimeInterval(-simUse),
                              lastClaudeWorking: now.addingTimeInterval(-3 * 3600),
                              lastAndroidUse: now.addingTimeInterval(-5 * 3600),
                              kept: [])
        demo = demo.map { item in
            var i = item
            let track = Track(firstSeen: i.started, heavySince: i.started,
                              lastConnection: i.ports.isEmpty || i.connections > 0 ? nil : now.addingTimeInterval(-2 * 3600))
            i.status = Rules.status(i, track: track, ctx: ctx)
            return i
        }
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


    /// One example screen per group of row types, so every kind of warning can be seen.
    static func examples(_ name: String,
                         item: (ItemKind, String, String, Double, Double, Verdict, String?, Double?, [UInt16]) -> Item,
                         stuck: Item, loop: Item, sim: Item, site: Item) -> ([Item], Bool) {
        let now = Date()
        func make(_ kind: ItemKind, _ title: String, hours: Double, perHour: Double, _ level: Level, _ tag: String,
                  project: String? = nil, ports: [UInt16] = [], noun: String = "") -> Item {
            var i = item(kind, title, "", hours, perHour, Verdict(level: level, tag: tag), project, nil, ports)
            i.noun = noun
            return i
        }
        switch name {
        case "clear":
            return ([], false)
        case "quiet":
            var live = make(.sessionJob, "Dev server (Vite) on port 5174", hours: 0.5, perHour: 0.3, .none, "",
                            project: "morse-waldo", ports: [5174], noun: "Test website")
            live.connections = 1
            var simInUse = sim; simInUse.verdict = Verdict(level: .none, tag: ""); simInUse.started = now.addingTimeInterval(-3600)
            return ([site, live, simInUse], false)
        case "leftovers":
            return ([stuck, loop, site], true)
        case "devices":
            var emu = make(.android, "Pixel 8", hours: 6, perHour: 6, .warn, "Unused 5 h", noun: "Android emulator")
            emu.cpuPercent = 60
            return ([sim, emu], false)
        case "claude", "chats":
            var chat = make(.chatHelper, "Project ideas", hours: 0.33, perHour: 6, .warn, "Stuck", noun: "Chat helper")
            chat.memoryMB = 240; chat.idleSince = now.addingTimeInterval(-3 * 3600)
            var pile = make(.helperPileup, "9 chat helpers", hours: 0, perHour: 0, .warn, "Pile-up", noun: "Chat helpers")
            pile.memoryMB = 1650; pile.batteryPerHour = nil
            pile.apps = ["Snail House levels", "Project ideas", "Rectangle app deletion", "Cloudflare email domain",
                         "DesktopCatProject setup", "Scheduled actions", "Auto-approve for all projects", "Zom-Zom guns", "Pokémon maps"]
            var preview = make(.claudePreview, "Claude app windows", hours: 0.67, perHour: 4, .warn, "Busy preview", noun: "Claude app")
            preview.cpuPercent = 42
            preview.notes = ["Busiest part: a side panel or preview (38% CPU)", "Claude windows on screen: 2", "Claude in front: no (busy in the background)"]
            return name == "chats" ? ([pile], false) : ([chat, pile, preview], name == "claude")
        case "system":
            var spot = make(.spotlight, "Spotlight indexing", hours: 0.33, perHour: 0, .warn, "Indexing", noun: "Spotlight")
            spot.apps = ["~/Desktop/claude/prayer-circle/node_modules", "~/Desktop/claude/snail-house/node_modules",
                         "~/Desktop/claude/leftovers/.build"]
            spot.batteryPerHour = nil
            var sync = make(.cloudSync, "Cloud sync", hours: 0.5, perHour: 0, .warn, "Syncing", noun: "Cloud sync")
            sync.apps = ["~/Documents/apps/our-sims/node_modules"]; sync.batteryPerHour = nil
            return ([spot, sync], false)
        default:
            return ([stuck, loop, sim, site], false)
        }
    }
}
