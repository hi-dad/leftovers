import Foundation

enum Level: Int, Codable, Comparable {
    case none = 0     // nothing to say
    case info = 1     // menu only
    case warn = 2     // orange: notify once
    case alarm = 3    // red: notify once, red count in the menu bar

    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
}

struct Verdict: Codable, Equatable {
    var level: Level
    var tag: String          // short label on the row ("Looks stuck")
    var message: String = "" // notification text
}

/// What Leftovers remembers about a row between scans.
struct Track: Codable, Equatable {
    var firstSeen: Date
    var heavySince: Date?
    var lastConnection: Date?
}

struct RuleContext {
    var now: Date
    var onBattery: Bool
    var lastSimulatorUse: Date?   // Simulator app in front, or Claude's simulator panel streaming
    var lastClaudeWorking: Date   // a Claude Code session doing something
    var lastAndroidUse: Date? = nil  // the Android emulator window in front
    var lastChromeUse: Date? = nil   // Chrome in front
    var kept: Set<String>
    var speedup: Double = 1
}

/// Decides how worried to be about each row. Pure, so every rule is tested.
enum Rules {
    /// Claude pre-loads at most 6 chats on its own (its log: "cap=6"), but every chat you open stays loaded until
    /// memory runs low, so this counts how many are loaded at once.
    static let helperPileup = 15

    static func isHeavy(_ i: Item) -> Bool { i.cpuPercent >= 15 || (i.batteryPerHour ?? 0) >= 2 }

    /// When this row became heavy, carried over from the last scan. A process that has averaged
    /// heavy use over its whole life counts as heavy since it started (so a job stuck for two days
    /// is flagged at once, not 30 minutes after Leftovers launches).
    static func updateTrack(_ old: Track?, item: Item, now: Date) -> Track {
        var t = old ?? Track(firstSeen: now)
        if isHeavy(item) {
            if t.heavySince == nil {
                t.heavySince = (old == nil && item.averageCpu >= 15) ? item.started : now
            }
        } else {
            t.heavySince = nil
        }
        if item.connections > 0 { t.lastConnection = now }
        return t
    }

    /// The subheader, in one style for every row: how long it has been going · when it last did something.
    static func status(_ i: Item, track: Track, ctx: RuleContext) -> String {
        let now = ctx.now
        func dur(_ since: Date) -> String { Describe.duration(now.timeIntervalSince(since)) }
        func ago(_ d: Date?) -> String? {
            guard let d else { return nil }
            let t = now.timeIntervalSince(d)
            return t < 60 ? "just now" : Describe.duration(t) + " ago"
        }
        let busy = "Busy " + dur(track.heavySince ?? now)
        var parts: [String]
        switch i.kind {
        case .leftover, .appStarted, .sessionJob:
            parts = ["Running " + dur(i.started)]
            if !i.ports.isEmpty {
                parts.append(i.connections > 0 ? "\(i.connections) visitor\(i.connections == 1 ? "" : "s") now"
                             : ago(track.lastConnection).map { "last visit " + $0 } ?? "no visits yet")
            } else if let out = ago(i.lastOutput) {
                parts.append("last change " + out)
            } else if i.kind == .leftover {
                parts.append("no saved changes")
            }
        case .simulator, .android:
            let use = i.kind == .simulator ? ctx.lastSimulatorUse : ctx.lastAndroidUse
            if let use, use > i.started, let a = ago(use) { parts = ["Running " + dur(i.started), "last used " + a] }
            else { parts = ["Running " + dur(i.started), "not used yet"] }
        case .browserTab:
            parts = ["Open " + dur(track.firstSeen), ago(ctx.lastChromeUse).map { "Chrome last used " + $0 } ?? "Chrome not used since"]
        case .chatHelper:
            parts = i.busy ? ["Working now"] : [busy, "last message " + (ago(i.idleSince) ?? "a while ago")]
        case .helperPileup:
            parts = ["\(i.apps.count) chats loaded", String(format: "%.1f GB of memory", (i.memoryMB ?? 0) / 1024)]
        case .claudePreview:
            parts = [busy, "last Claude work " + (ago(ctx.lastClaudeWorking) ?? "a while ago")]
        case .spotlight, .cloudSync:
            parts = [busy, "\(i.apps.count) build folder\(i.apps.count == 1 ? "" : "s") changed"]
        case .chromeExtension:
            parts = [busy, ago(ctx.lastChromeUse).map { "Chrome last used " + $0 } ?? "Chrome not used since"]
        }
        if ctx.kept.contains(i.keepKey) { parts.append("kept") }
        return parts.joined(separator: " · ")
    }

    static func judge(_ i: Item, track: Track, ctx: RuleContext) -> Verdict {
        // Stricter on battery. (`defaults write com.danielryan.Leftovers ruleSpeedup 60` makes every wait
        // 60x shorter, for testing.)
        let scale = (ctx.onBattery ? 0.5 : 1.0) / ctx.speedup
        let now = ctx.now
        let min = 60.0, hour = 3600.0

        if ctx.kept.contains(i.keepKey) { return Verdict(level: .info, tag: "Kept") }

        let cost = i.batteryPerHour.map { $0 >= 1 ? String(format: " It's using about %.0f%% of your battery an hour.", $0) : "" } ?? ""
        let heavyFor = track.heavySince.map { now.timeIntervalSince($0) } ?? 0
        let idleServer: TimeInterval? = i.ports.isEmpty || i.connections > 0 ? nil
            : now.timeIntervalSince(track.lastConnection ?? max(track.firstSeen, i.started))

        switch i.kind {
        case .leftover:
            let by = i.session.map { " Left by “\($0)”." } ?? ""
            if i.connections > 0 { return Verdict(level: .none, tag: "In use") }
            if isHeavy(i), heavyFor >= 30 * min * scale,
               let out = i.lastOutput, now.timeIntervalSince(out) >= 30 * min * scale {
                return Verdict(level: .alarm, tag: "Looks stuck",
                               message: "\(i.title) has been working hard for \(Describe.duration(heavyFor)) but hasn't made progress in \(Describe.duration(now.timeIntervalSince(out))).\(by)\(cost)")
            }
            if isHeavy(i), heavyFor >= 10 * min * scale {
                return Verdict(level: .warn, tag: "Forgotten",
                               message: "\(i.title) kept running after its Claude session ended.\(by)\(cost)")
            }
            if let idle = idleServer, idle >= hour * scale {
                return Verdict(level: .info, tag: "Idle \(Describe.duration(idle))")
            }
            return Verdict(level: .info, tag: "Left behind")

        case .appStarted, .sessionJob:
            // A server nobody has visited for 10 minutes is inactive (listed, never a warning).
            if let idle = idleServer, idle >= 10 * min * scale {
                return Verdict(level: .info, tag: "Idle \(Describe.duration(idle))")
            }
            return Verdict(level: .none, tag: "")

        case .simulator:
            let unused = now.timeIntervalSince(max(i.started, ctx.lastSimulatorUse ?? .distantPast))
            if unused >= 2 * hour * scale {
                return Verdict(level: .warn, tag: "Unused \(Describe.duration(unused))",
                               message: "\(i.title) has been running for \(Describe.duration(now.timeIntervalSince(i.started))) and hasn't been used in \(Describe.duration(unused)).\(cost)")
            }
            return unused >= 30 * min * scale ? Verdict(level: .info, tag: "Inactive") : Verdict(level: .none, tag: "")

        case .android:
            let unused = now.timeIntervalSince(max(i.started, ctx.lastAndroidUse ?? .distantPast))
            if unused >= 2 * hour * scale {
                return Verdict(level: .warn, tag: "Unused \(Describe.duration(unused))",
                               message: "\(i.title) has been running for \(Describe.duration(now.timeIntervalSince(i.started))) and hasn't been used in \(Describe.duration(unused)).\(cost)")
            }
            return unused >= 30 * min * scale ? Verdict(level: .info, tag: "Inactive") : Verdict(level: .none, tag: "")

        case .claudePreview:
            // Drawing while Claude works is normal (it's showing the reply). Busy with nothing happening is not.
            let idle = now.timeIntervalSince(ctx.lastClaudeWorking)
            if isHeavy(i), heavyFor >= 10 * min * scale, idle >= 5 * min {
                return Verdict(level: .warn, tag: "Busy preview",
                               message: "The Claude app has been busy drawing for \(Describe.duration(heavyFor)) while no chat is working. Usually an animated preview or artifact is still open.\(cost)")
            }
            return Verdict(level: .none, tag: "")

        case .spotlight, .cloudSync:
            let who = i.kind == .spotlight ? "Spotlight has been indexing" : "Your cloud sync has been uploading"
            if heavyFor >= 15 * min * scale {
                return Verdict(level: .warn, tag: i.kind == .spotlight ? "Indexing" : "Syncing",
                               message: "\(who) Claude's build files for \(Describe.duration(heavyFor)) (\(i.apps.prefix(2).joined(separator: ", ")))." )
            }
            return Verdict(level: .none, tag: "")

        case .browserTab:
            let open = now.timeIntervalSince(track.firstSeen)
            let unused = now.timeIntervalSince(ctx.lastChromeUse ?? track.firstSeen)
            guard open >= 30 * min * scale, unused >= 30 * min * scale else { return Verdict(level: .none, tag: "") }
            if isHeavy(i), heavyFor >= 10 * min * scale {
                return Verdict(level: .warn, tag: "Tab busy",
                               message: "A Chrome tab with one of Claude's test pages has been open for \(Describe.duration(open)) and Chrome is busy, though you haven't used Chrome in \(Describe.duration(unused)).")
            }
            return Verdict(level: .info, tag: "Open tab")

        case .chatHelper:
            if i.busy { return Verdict(level: .none, tag: "Working") }
            let idle = now.timeIntervalSince(i.idleSince ?? i.started)
            // Says it's idle but keeps the CPU busy: stuck in a loop (a known Claude Code bug).
            if isHeavy(i), heavyFor >= 10 * min * scale, idle >= 10 * min {
                return Verdict(level: .warn, tag: "Stuck",
                               message: "The helper for your “\(i.title)” chat has been busy for \(Describe.duration(heavyFor)) although the chat is idle.\(cost)")
            }
            // Old idle chats are fine: Claude keeps up to 6 loaded and closes the oldest itself.
            return Verdict(level: .none, tag: "Idle \(Describe.duration(idle))")

        case .helperPileup:
            return Verdict(level: .warn, tag: "Pile-up",
                           message: "The Claude app has \(i.title) loaded. They hold about \(String(format: "%.1f", (i.memoryMB ?? 0) / 1024)) GB of memory. Quitting and reopening Claude clears them.")

        case .chromeExtension:
            if isHeavy(i), heavyFor >= 10 * min * scale {
                return Verdict(level: .warn, tag: "Spinning",
                               message: "A Chrome extension has been busy in the background for \(Describe.duration(heavyFor)).\(cost)")
            }
            return Verdict(level: .none, tag: "")

        }
    }
}
