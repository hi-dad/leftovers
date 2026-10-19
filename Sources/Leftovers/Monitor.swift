import AppKit
import Combine
import Foundation

/// Scans on a background queue and publishes the menu's rows.
final class Monitor: NSObject, ObservableObject {
    static let shared = Monitor()

    @Published private(set) var items: [Item] = []
    @Published private(set) var battery = SystemInfo.battery()
    @Published private(set) var scannedAt: Date?
    /// Called on the main thread after each scan, with whether the Mac was on battery before it.
    var onScanned: ((Bool) -> Void)?

    // Memory between scans (see Rules).
    var tracks: [String: Track] = [:]
    var lastSimulatorUse: Date?
    var lastAndroidUse: Date?
    var lastClaudeWorking = SessionIndex.load().sessions.values.map(\.lastActivityAt).max() ?? Date()
    /// Checks switched off in Settings: their rows are never shown or notified.
    @Published var offChecks: Set<Check> {
        didSet { UserDefaults.standard.set(offChecks.map(\.rawValue), forKey: "offChecks") }
    }
    @Published var kept: [String: String] {   // keepKey → label (things you said you're still using)
        didSet { UserDefaults.standard.set(kept, forKey: "kept") }
    }

    override init() {
        kept = (UserDefaults.standard.dictionary(forKey: "kept") as? [String: String]) ?? [:]
        offChecks = Set(((UserDefaults.standard.array(forKey: "offChecks") as? [String]) ?? []).compactMap(Check.init(rawValue:)))
        super.init()
    }

    private let queue = DispatchQueue(label: "leftovers.scan", qos: .utility)
    private var previous: [pid_t: Sample] = [:]
    /// "pid-starttime" → name of the chat that started it (see compute). Kept on disk so a Leftovers restart
    /// doesn't forget. Only touched on the scan queue.
    private var remembered: [String: String] = {
        guard let d = try? Data(contentsOf: Monitor.rememberedURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: d)) ?? [:]
    }()
    private static let rememberedURL = statusURL.deletingLastPathComponent().appendingPathComponent("remembered.json")

    private func saveRemembered() {
        try? JSONEncoder().encode(remembered).write(to: Self.rememberedURL, options: .atomic)
    }
    private var timer: Timer?
    private var scanning = false

    private struct Sample { var at: Date; var start: Date; var cpu: Double; var joules: Double }

    static let statusURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Leftovers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("status.json")
    }()

    func start() {
        scan()
        // A quick second look so the first numbers are current rates, not lifetime averages.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.scan() }
    }

    /// Checks every minute on battery, every 3 minutes when plugged in.
    private func scheduleNext() {
        timer?.invalidate()
        let interval: TimeInterval = battery.onBattery ? 60 : 180
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in self?.scan() }
        t.tolerance = interval * 0.2   // lets macOS batch wakeups
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        queue.async { [weak self] in
            guard let self else { return }
            let (raw, battery, facts) = self.compute(now: Date())
            DispatchQueue.main.async {
                let wasOnBattery = self.battery.onBattery
                self.battery = battery
                self.judge(raw, facts: facts, now: Date())
                self.onScanned?(wasOnBattery)
                self.scannedAt = Date()
                self.scanning = false
                self.writeStatus()
                self.scheduleNext()
            }
        }
    }

    /// For testing from Terminal: `Leftovers --once` prints one scan (two samples, 3 s apart) as JSON.
    func printOnce() {
        _ = compute(now: Date())
        Thread.sleep(forTimeInterval: 3)
        let (raw, battery, facts) = compute(now: Date())
        self.battery = battery; self.scannedAt = Date()
        judge(raw, facts: facts, now: Date())
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        print(String(decoding: try! enc.encode(Status(scannedAt: Date(), battery: battery, items: items)), as: UTF8.self))
    }

    /// Example rows for the README picture (see DemoRender).
    func showDemo(_ demo: [Item]) { items = demo; scannedAt = Date() }

    /// Applies the alarm rules to a fresh scan and publishes it (main thread).
    func judge(_ raw: [Item], facts: Facts, now: Date) {
        if facts.claudeWorking { lastClaudeWorking = now }
        if facts.simPanelActive { lastSimulatorUse = now }
        let ctx = RuleContext(now: now, onBattery: battery.onBattery, lastSimulatorUse: lastSimulatorUse,
                              lastClaudeWorking: lastClaudeWorking, lastAndroidUse: lastAndroidUse, kept: Set(kept.keys),
                              speedup: max(1, UserDefaults.standard.double(forKey: "ruleSpeedup")))
        var newTracks: [String: Track] = [:]
        items = raw.filter { !offChecks.contains(Check.of($0)) }.map { item in
            var i = item
            let t = Rules.updateTrack(tracks[i.id], item: i, now: now)
            newTracks[i.id] = t
            i.verdict = Rules.judge(i, track: t, ctx: ctx)
            i.status = Rules.status(i, track: t, ctx: ctx)
            return i
        }.filter { $0.kind != .sessionJob || !$0.ports.isEmpty || $0.verdict.level > .none || $0.verdict.tag == "Ignored" }
        tracks = newTracks
        // A keep only lasts while that run is going: forget keeps for things that have stopped.
        let live = Set(items.map(\.keepKey))
        if kept.keys.contains(where: { !live.contains($0) }) { kept = kept.filter { live.contains($0.key) } }
    }

    /// For testing from Terminal: `Leftovers --stop <text>` stops (or closes) the first row whose title contains it.
    func stopOnce(matching text: String) {
        _ = compute(now: Date()); Thread.sleep(forTimeInterval: 2)
        let (raw, _, facts) = compute(now: Date())
        judge(raw, facts: facts, now: Date())
        guard let i = items.first(where: { canStop($0) && $0.title.contains(text) }) else { print("no match"); return }
        print("stopping", i.title, i.pids)
        stop(i)
        RunLoop.main.run(until: Date().addingTimeInterval(7))
        print("still alive:", zip(i.pids, i.startTimes).filter { ProcScan.startTime($0.0) == $0.1 }.map(\.0))
    }

    // MARK: building the rows (background queue)

    struct Facts { var claudeWorking = false, simPanelActive = false }

    private func compute(now: Date) -> ([Item], BatteryState, Facts) {
        var facts = Facts()
        let battery = SystemInfo.battery()
        let procs = ProcScan.allProcesses()
        let sessions = SessionIndex.load()
        // Claude Code's settings folder: ~/.claude, unless Claude was told to keep it elsewhere (CLAUDE_CONFIG_DIR,
        // read from a running Claude Code process so it matches whatever that person set up).
        let probe = Classifier()
        let configDir = procs.lazy.filter(probe.isClaudeCode)
            .compactMap { ProcScan.environmentValue($0.pid, "CLAUDE_CONFIG_DIR") }.first ?? probe.configDir
        let helpers = HelperInfo.load(from: configDir + "/sessions")
        // (`defaults write com.danielryan.Leftovers testFolders -array <folder>` adds folders, for testing only.)
        let testFolders = (UserDefaults.standard.array(forKey: "testFolders") as? [String]) ?? []
        let classifier = Classifier(watchedFolders: sessions.workFolders + testFolders, configDir: configDir,
                                    remembered: Set(remembered.keys))
        let g = classifier.group(procs)

        // Remember everything a chat (or the Claude app) starts, with the chat's name, so it's still recognised
        // as Claude's after the chat closes, whatever folder it runs in. "" = started by the app, no chat name.
        for fam in g.sessionJobs {
            let chat = helpers[fam[0].ppid]?.name ?? ""
            for p in fam { remembered[Classifier.key(p)] = chat }
        }
        for fam in g.appStarted { for p in fam where remembered[Classifier.key(p)] == nil { remembered[Classifier.key(p)] = "" } }
        let alive = Set(procs.map(Classifier.key))
        remembered = remembered.filter { alive.contains($0.key) }
        saveRemembered()

        var samples: [pid_t: Sample] = [:]
        /// Current CPU % and watts of one process (lifetime average the first time it is seen).
        func rate(_ p: ProcRecord) -> (cpu: Double, watts: Double, average: Double) {
            guard let u = ProcScan.usage(p.pid) else { return (0, 0, 0) }
            let s = Sample(at: now, start: p.start, cpu: u.cpu, joules: u.joules)
            samples[p.pid] = s
            let age = max(now.timeIntervalSince(p.start), 1)
            if let old = previous[p.pid], old.start == p.start, now.timeIntervalSince(old.at) > 1 {
                let dt = now.timeIntervalSince(old.at)
                return (max(0, (u.cpu - old.cpu) / dt * 100), max(0, (u.joules - old.joules) / dt), u.cpu / age * 100)
            }
            return (u.cpu / age * 100, u.joules / age, u.cpu / age * 100)
        }
        func perHour(_ watts: Double) -> Double? {
            battery.capacityWh > 0 ? watts / battery.capacityWh * 100 : nil
        }

        struct FamilyStats { var cpu = 0.0, watts = 0.0, average = 0.0, writes: [WrittenFile] = [], ports: [UInt16] = [], connections = 0, heaviest: ProcRecord? }
        func stats(_ fam: [ProcRecord]) -> FamilyStats {
            var st = FamilyStats(), top = -1.0
            for p in fam {
                let r = rate(p)
                st.cpu += r.cpu; st.watts += r.watts; st.average += r.average
                if r.cpu > top { top = r.cpu; st.heaviest = p }
                let f = ProcScan.openFiles(p.pid)
                st.writes += f.writes
                st.ports += f.listening
                st.connections += f.established.filter { f.listening.contains($0) }.count
            }
            st.ports = Array(Set(st.ports)).sorted()
            return st
        }

        func familyItem(_ fam: [ProcRecord], kind: ItemKind) -> Item {
            let root = fam[0], st = stats(fam)
            let main = st.heaviest ?? root
            var title = Describe.title(for: main)
            if !st.ports.isEmpty, kind != .leftover || st.cpu < 1 {
                title += " on port " + st.ports.map(String.init).joined(separator: ", ")
            }
            let match = sessions.match(fam)
            let rememberedChat = fam.lazy.compactMap { self.remembered[Classifier.key($0)] }.first { !$0.isEmpty }
            var item = Item(id: "\(kind.rawValue)-\(root.pid)-\(Int(root.start.timeIntervalSince1970))",
                            kind: kind, title: title, detail: "", command: main.commandLine,
                            session: match?.session.title ?? rememberedChat,
                            sessionGuessed: match == nil ? false : match!.guessed,
                            project: classifier.project(for: root.cwd), folder: root.cwd.isEmpty ? nil : root.cwd, pids: fam.map(\.pid), started: root.start,
                            cpuPercent: st.cpu, watts: st.watts, batteryPerHour: perHour(st.watts),
                            ports: st.ports, connections: st.connections,
                            lastOutput: st.writes.map(\.modified).max(), averageCpu: st.average,
                            startTimes: fam.map { $0.start.timeIntervalSince1970 },
                            keepKey: "\(kind.rawValue)-\(root.pid)-\(Int(root.start.timeIntervalSince1970))",
                            noun: st.ports.isEmpty ? Describe.noun(for: main) : "Test website",
                            starter: main.pid != root.pid && root.name != main.name ? Describe.title(for: root) : nil)
            // A chat's own job: note whether that chat is replying right now (its job is never flagged then).
            if kind == .sessionJob { item.busy = helpers[root.ppid]?.busy ?? false }
            let age = Describe.duration(now.timeIntervalSince(root.start))
            switch kind {
            case .leftover:
                let by = item.session.map { "Left by “\($0)”" + (item.sessionGuessed ? " (probably)" : "") }
                    ?? "Its Claude session has ended"
                item.detail = "\(by) · running \(age)"
            case .sessionJob: item.detail = "Running for \(age)" + (item.session.map { " · “\($0)”" } ?? "")
            default: item.detail = "Running for \(age)"
            }
            if kind != .sessionJob, main.pid != root.pid, root.name != main.name {
                item.detail += " · started by " + Describe.title(for: root)
            }
            return item
        }

        var items: [Item] = []
        items += g.leftovers.map { familyItem($0, kind: .leftover) }
        // A session's own work is its business: only servers are shown (they have an Open button), plus jobs that
        // look stuck (dropped in `judge` otherwise, after their busy time is tracked).
        items += g.sessionJobs.map { familyItem($0, kind: .sessionJob) }
        items += g.appStarted.map { familyItem($0, kind: .appStarted) }.filter { $0.cpuPercent >= 2 || !$0.ports.isEmpty }

        // Simulators: everything running for that device (its launchd_sim family) counts toward it.
        var children: [pid_t: [ProcRecord]] = [:]
        for p in procs { children[p.ppid, default: []].append(p) }
        for sim in SystemInfo.bootedSimulators() {
            let tagged = procs.filter { $0.path.contains(sim.udid) || $0.args.contains { $0.contains(sim.udid) } }
            var fam: [ProcRecord] = [], seen = Set<pid_t>(), stack = tagged
            while let p = stack.popLast() {
                guard seen.insert(p.pid).inserted else { continue }
                fam.append(p); stack += children[p.pid] ?? []
            }
            let marker = "/Devices/\(sim.udid)/data/Containers/Bundle/Application/"
            let apps = Set(fam.filter { $0.path.contains(marker) }.map(\.name)).sorted()
            let st = stats(fam)
            let started = fam.map(\.start).min() ?? now
            items.append(Item(id: "sim-\(sim.udid)", kind: .simulator,
                              title: sim.name + (sim.runtime.isEmpty ? "" : " (\(sim.runtime))"),
                              detail: (apps.isEmpty ? "No app open" : "Running " + apps.joined(separator: ", "))
                                  + " · booted \(Describe.duration(now.timeIntervalSince(started))) ago",
                              command: "xcrun simctl shutdown \(sim.udid)",
                              pids: fam.map(\.pid), started: started, cpuPercent: st.cpu, watts: st.watts,
                              batteryPerHour: perHour(st.watts), averageCpu: st.average,
                              keepKey: "sim-\(sim.udid)-\(Int(started.timeIntervalSince1970))",
                              noun: sim.name.contains("iPad") ? "iPad simulator" : "iPhone simulator", apps: apps))
        }

        // The Claude app's own processes tell whether a session is working and whether Claude's simulator
        // panel is showing (used by the rules; not shown as a row).
        var renderCPU = 0.0, renderWatts = 0.0
        var renderers: [(pid: pid_t, cpu: Double, mb: Double)] = []
        for p in g.claudeApp {
            let r = rate(p)
            if p.name.contains("Renderer") {
                renderCPU += r.cpu; renderWatts += r.watts
                renderers.append((p.pid, r.cpu, ProcScan.usage(p.pid)?.memoryMB ?? 0))
            }
            // The graphics process does the actual drawing for animations and video, so it counts too.
            if p.args.contains("--type=gpu-process") { renderCPU += r.cpu; renderWatts += r.watts }
            // Claude's simulator panel streams frames while it is showing a simulator.
            if p.name == "claude-ios-sim", r.cpu >= 3 { facts.simPanelActive = true }
        }

        // Chat helpers: the background program behind each Claude chat. Each one says whether its chat is
        // busy, so "Claude is working" comes from that, not from CPU (a stuck helper is busy but not working).
        var helperItems: [Item] = []
        for p in g.sessions {
            var fam: [ProcRecord] = [], stack = [p]
            while let q = stack.popLast() { fam.append(q); stack += children[q.pid] ?? [] }
            let r = rate(p)
            let mem = fam.compactMap { ProcScan.usage($0.pid)?.memoryMB }.reduce(0, +)
            let info = helpers[p.pid]
            if info?.busy == true { facts.claudeWorking = true }
            helperItems.append(Item(id: "helper-\(p.pid)-\(Int(p.start.timeIntervalSince1970))", kind: .chatHelper,
                                    title: info?.name ?? "Claude chat (\(classifier.project(for: p.cwd) ?? "terminal"))",
                                    detail: "", command: p.commandLine.prefix(200).description,
                                    pids: fam.map(\.pid), started: p.start, cpuPercent: r.cpu, watts: r.watts,
                                    batteryPerHour: perHour(r.watts), averageCpu: r.average,
                                    startTimes: fam.map { $0.start.timeIntervalSince1970 },
                                    keepKey: "helper-\(info?.name ?? String(p.pid))", noun: "Chat helper",
                                    memoryMB: mem, idleSince: info.flatMap { $0.busy ? nil : $0.statusSince },
                                    busy: info?.busy ?? false))
        }
        items += helperItems
        // More than the app's own limit allows: it is failing to close old ones.
        if helperItems.count >= Rules.helperPileup {
            let mem = helperItems.compactMap(\.memoryMB).reduce(0, +)
            items.append(Item(id: "helper-pileup", kind: .helperPileup, title: "\(helperItems.count) chat helpers",
                              detail: "", command: "", pids: helperItems.flatMap(\.pids), started: now,
                              cpuPercent: helperItems.map(\.cpuPercent).reduce(0, +), keepKey: "helper-pileup",
                              noun: "Chat helpers", apps: helperItems.map(\.title), memoryMB: mem))
        }
        // Chats active in the last 10 minutes count as working too (covers helpers that write no status).
        if sessions.sessions.values.contains(where: { now.timeIntervalSince($0.lastActivityAt) < 600 }) {
            facts.claudeWorking = true
        }

        // #7 The Claude app's windows drawing hard (usually an animated preview or artifact left open).
        if renderCPU >= 10 {
            // Electron doesn't label its window processes, but the biggest one is the main window,
            // so the busiest one can be told apart as "main window" or "a side panel or preview".
            let main = renderers.max { $0.mb < $1.mb }?.pid
            let busiest = renderers.max { $0.cpu < $1.cpu }
            var notes: [String] = []
            if let b = busiest {
                notes.append("Busiest part: " + (b.pid == main ? "the main Claude window" : "a side panel or preview")
                             + String(format: " (%.0f%% CPU)", b.cpu))
            }
            let appPid = procs.first { $0.path == Classifier.claudeAppMain }?.pid
            let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
                .filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == appPid && ($0[kCGWindowLayer as String] as? Int) == 0 }.count
            notes.append("Claude windows on screen: \(windows)")
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.anthropic.claudefordesktop"
            notes.append("Claude in front: " + (front ? "yes" : "no (busy in the background)"))
            // Something playing (a video, a simulator stream, or a busy side panel/preview) vs. no clear reason.
            let video = appPid.map(SystemInfo.isPlayingVideo) ?? false
            let what: String? = video ? "Video" : facts.simPanelActive ? "Simulator screen"
                : (busiest != nil && busiest?.pid != main) ? "Animation or artifact" : nil
            if let what { notes.insert("Playing: " + what.lowercased(), at: 0) }
            items.append(Item(id: what == nil ? "claude-preview" : "claude-playback",
                              kind: what == nil ? .claudePreview : .claudePlayback, title: "Claude app windows",
                              detail: "", command: "Claude Helper (Renderer)", pids: renderers.map(\.pid),
                              started: now, cpuPercent: renderCPU, watts: renderWatts, batteryPerHour: perHour(renderWatts),
                              keepKey: what == nil ? "claude-preview" : "claude-playback",
                              noun: what ?? "Claude app", notes: notes))
        }

        // #8 / #9 Spotlight and cloud-sync apps chewing on Claude's build folders. System processes are
        // measured with ps; folders are only looked at while one of them is busy.
        let cpuByName = Extras.systemCPU()
        func cpu(of names: Set<String>) -> Double {
            cpuByName.filter { names.contains($0.name) }.map(\.cpu).reduce(0, +)
        }
        let claudeFolders = classifier.watchedFolders
        let spotlightCPU = cpu(of: Extras.spotlightProcesses)
        if spotlightCPU >= 20 {
            let folders = Extras.recentBuildFolders(in: claudeFolders, within: 3 * 3600, now: now)
            if !folders.isEmpty {
                items.append(Item(id: "spotlight", kind: .spotlight, title: "Spotlight indexing",
                                  detail: "", command: "mds_stores / mdworker", pids: [], started: now,
                                  cpuPercent: spotlightCPU, keepKey: "spotlight", noun: "Spotlight", apps: folders))
            }
        }
        let synced = Extras.syncedFolders(claudeFolders)
        let syncCPU = cpu(of: Extras.syncProcesses)
        if !synced.isEmpty, syncCPU >= 15 {
            let folders = Extras.recentBuildFolders(in: synced, within: 3 * 3600, now: now)
            if !folders.isEmpty {
                items.append(Item(id: "cloud-sync", kind: .cloudSync, title: "Cloud sync",
                                  detail: "", command: "iCloud / OneDrive / Dropbox", pids: [], started: now,
                                  cpuPercent: syncCPU, keepKey: "cloud-sync", noun: "Cloud sync", apps: folders))
            }
        }

        // #12 Android emulators (the emulator runs as a qemu process).
        for p in procs where p.name.hasPrefix("qemu-system") {
            var fam: [ProcRecord] = [], stack = [p]
            while let q = stack.popLast() { fam.append(q); stack += children[q.pid] ?? [] }
            let st = stats(fam)
            let avd = p.args.firstIndex(of: "-avd").flatMap { $0 + 1 < p.args.count ? p.args[$0 + 1] : nil }
                ?? p.args.first { $0.hasPrefix("@") }.map { String($0.dropFirst()) } ?? "Android device"
            items.append(Item(id: "android-\(p.pid)-\(Int(p.start.timeIntervalSince1970))", kind: .android,
                              title: avd.replacingOccurrences(of: "_", with: " "), detail: "", command: p.commandLine,
                              pids: fam.map(\.pid), started: p.start, cpuPercent: st.cpu, watts: st.watts,
                              batteryPerHour: perHour(st.watts), averageCpu: st.average,
                              startTimes: fam.map { $0.start.timeIntervalSince1970 },
                              keepKey: "android-\(avd)-\(Int(p.start.timeIntervalSince1970))", noun: "Android emulator"))
        }

        previous = samples
        return (items, battery, facts)
    }

    private func writeStatus() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let status = Status(scannedAt: scannedAt ?? Date(), battery: battery, items: items)
        try? enc.encode(status).write(to: Self.statusURL, options: .atomic)
    }
}
