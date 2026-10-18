import Combine
import Foundation

/// Scans on a background queue and publishes the menu's rows.
final class Monitor: NSObject, ObservableObject {
    static let shared = Monitor()

    @Published private(set) var items: [Item] = []
    @Published private(set) var battery = SystemInfo.battery()
    @Published private(set) var scannedAt: Date?
    @Published private(set) var ownWatts: Double = -1
    /// Called on the main thread after each scan, with whether the Mac was on battery before it.
    var onScanned: ((Bool) -> Void)?

    // Memory between scans (see Rules).
    var tracks: [String: Track] = [:]
    var lastSimulatorUse: Date?
    var lastClaudeWorking = SessionIndex.load().sessions.values.map(\.lastActivityAt).max() ?? Date()
    @Published var kept: [String: String] {   // keepKey → label shown in Settings
        didSet { UserDefaults.standard.set(kept, forKey: "kept") }
    }
    var snoozedUntil: [String: Date] = [:]

    override init() {
        kept = (UserDefaults.standard.dictionary(forKey: "kept") as? [String: String]) ?? [:]
        super.init()
    }

    private let queue = DispatchQueue(label: "leftovers.scan", qos: .utility)
    private var previous: [pid_t: Sample] = [:]
    private var ownBaseline: Sample?
    private let launchedAt = Date()
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
            let (raw, battery, own, facts) = self.compute(now: Date())
            DispatchQueue.main.async {
                let wasOnBattery = self.battery.onBattery
                self.battery = battery
                self.judge(raw, facts: facts, now: Date())
                self.onScanned?(wasOnBattery)
                self.ownWatts = own
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
        let (raw, battery, _, facts) = compute(now: Date())
        self.battery = battery; self.scannedAt = Date()
        judge(raw, facts: facts, now: Date())
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        print(String(decoding: try! enc.encode(Status(scannedAt: Date(), battery: battery, items: items)), as: UTF8.self))
    }

    /// Applies the alarm rules to a fresh scan and publishes it (main thread).
    func judge(_ raw: [Item], facts: Facts, now: Date) {
        if facts.claudeWorking { lastClaudeWorking = now }
        if facts.simPanelActive { lastSimulatorUse = now }
        let ctx = RuleContext(now: now, onBattery: battery.onBattery, lastSimulatorUse: lastSimulatorUse,
                              lastClaudeWorking: lastClaudeWorking, kept: Set(kept.keys), snoozedUntil: snoozedUntil,
                              speedup: max(1, UserDefaults.standard.double(forKey: "ruleSpeedup")))
        var newTracks: [String: Track] = [:]
        items = raw.map { item in
            var i = item
            let t = Rules.updateTrack(tracks[i.id], item: i, now: now)
            newTracks[i.id] = t
            i.verdict = Rules.judge(i, track: t, ctx: ctx)
            return i
        }
        tracks = newTracks
        snoozedUntil = snoozedUntil.filter { $0.value > now }
    }

    /// For testing from Terminal: `Leftovers --stop <text>` stops the first leftover whose title contains it.
    func stopOnce(matching text: String) {
        _ = compute(now: Date()); Thread.sleep(forTimeInterval: 2)
        let (raw, _, _, facts) = compute(now: Date())
        judge(raw, facts: facts, now: Date())
        guard let i = items.first(where: { $0.kind == .leftover && $0.title.contains(text) }) else { print("no match"); return }
        print("stopping", i.title, i.pids)
        stop(i)
        RunLoop.main.run(until: Date().addingTimeInterval(7))
        print("still alive:", zip(i.pids, i.startTimes).filter { ProcScan.startTime($0.0) == $0.1 }.map(\.0))
    }

    // MARK: building the rows (background queue)

    struct Facts { var claudeWorking = false, simPanelActive = false }

    private func compute(now: Date) -> ([Item], BatteryState, Double, Facts) {
        var facts = Facts()
        let battery = SystemInfo.battery()
        let procs = ProcScan.allProcesses()
        let sessions = SessionIndex.load()
        let classifier = Classifier()
        let g = classifier.group(procs)

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
            var item = Item(id: "\(kind.rawValue)-\(root.pid)-\(Int(root.start.timeIntervalSince1970))",
                            kind: kind, title: title, detail: "", command: main.commandLine,
                            session: match?.session.title, sessionGuessed: match?.guessed ?? false,
                            project: classifier.project(for: root.cwd), folder: root.cwd.isEmpty ? nil : root.cwd, pids: fam.map(\.pid), started: root.start,
                            cpuPercent: st.cpu, watts: st.watts, batteryPerHour: perHour(st.watts),
                            ports: st.ports, connections: st.connections,
                            lastOutput: st.writes.map(\.modified).max(), averageCpu: st.average,
                            startTimes: fam.map { $0.start.timeIntervalSince1970 },
                            keepKey: "\(classifier.project(for: root.cwd) ?? root.cwd)|\(Describe.title(for: main))")
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
        // Claude's own helpers (tool servers, shells) sit idle most of the time; only busy or serving ones are shown.
        items += g.sessionJobs.map { familyItem($0, kind: .sessionJob) }.filter { $0.cpuPercent >= 2 || !$0.ports.isEmpty }
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
                              keepKey: "sim-\(sim.udid)-\(Int(started.timeIntervalSince1970))"))
        }

        // Sleep holds taken by Claude or by anything Claude started.
        let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let claudePids = Set((g.claudeApp + g.sessions + (g.leftovers + g.sessionJobs + g.appStarted).flatMap { $0 }).map(\.pid))
        let holds = Dictionary(grouping: SystemInfo.sleepHolds().filter { claudePids.contains($0.pid) }, by: \.pid)
        for (pid, list) in holds {
            let since = list.map(\.since).min() ?? now
            let who = byPid[pid].map { classifier.isClaudeApp($0) ? "The Claude app" : Describe.title(for: $0) } ?? "Claude"
            let what = list.contains { $0.type.contains("Display") } ? "keeping your screen on" : "stopping your Mac from sleeping"
            items.append(Item(id: "sleep-\(pid)", kind: .sleepHold, title: "\(who) is \(what)",
                              detail: "For \(Describe.duration(now.timeIntervalSince(since)))",
                              command: list.map { "\($0.type): \($0.name)" }.joined(separator: "; "),
                              pids: [pid], started: since, keepKey: "sleep-\(who)"))
        }

        // The Claude app's own cost, for comparison.
        let appProcs = g.claudeApp + g.sessions
        if !appProcs.isEmpty {
            var watts = 0.0, cpu = 0.0
            let sessionPids = Set(g.sessions.map(\.pid))
            for p in appProcs {
                let r = rate(p); watts += r.watts; cpu += r.cpu
                // Claude's simulator panel streams frames while it is showing a simulator.
                if p.name == "claude-ios-sim", r.cpu >= 3 { facts.simPanelActive = true }
                // A session is working when its Claude Code process is busy...
                if sessionPids.contains(p.pid), r.cpu >= 1 { facts.claudeWorking = true }
            }
            // ...or it was active in the last 10 minutes.
            if sessions.sessions.values.contains(where: { now.timeIntervalSince($0.lastActivityAt) < 600 }) {
                facts.claudeWorking = true
            }
            items.append(Item(id: "claude-app", kind: .claudeApp, title: "Claude",
                              detail: "\(g.claudeApp.count) app processes · \(g.sessions.count) Claude Code session\(g.sessions.count == 1 ? "" : "s") active",
                              command: Classifier.claudeAppMain, pids: appProcs.map(\.pid),
                              started: appProcs.map(\.start).min() ?? now,
                              cpuPercent: cpu, watts: watts, batteryPerHour: perHour(watts), keepKey: "claude"))
        }

        // Leftovers' own cost, shown in the footer so it is easy to see it stays light. Averaged from a
        // baseline taken after the busy first minute, so it reflects normal running (-1 = still measuring).
        var own = -1.0
        if let u = ProcScan.usage(getpid()) {
            if let base = ownBaseline {
                let dt = now.timeIntervalSince(base.at)
                if dt >= 50 { own = max(0, (u.joules - base.joules) / dt) }
            } else if now.timeIntervalSince(launchedAt) >= 60 {
                ownBaseline = Sample(at: now, start: launchedAt, cpu: u.cpu, joules: u.joules)
            }
        }

        previous = samples
        return (items, battery, own, facts)
    }

    private func writeStatus() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let status = Status(scannedAt: scannedAt ?? Date(), battery: battery, items: items)
        try? enc.encode(status).write(to: Self.statusURL, options: .atomic)
    }
}
