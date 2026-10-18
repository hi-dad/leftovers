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
    var kept: Set<String>
    var snoozedUntil: [String: Date]
    var speedup: Double = 1
}

/// Decides how worried to be about each row. Pure, so every rule is tested.
enum Rules {
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

    static func judge(_ i: Item, track: Track, ctx: RuleContext) -> Verdict {
        // Stricter on battery. (`defaults write com.danielryan.Leftovers ruleSpeedup 60` makes every wait
        // 60x shorter, for testing.)
        let scale = (ctx.onBattery ? 0.5 : 1.0) / ctx.speedup
        let now = ctx.now
        let min = 60.0, hour = 3600.0

        if ctx.kept.contains(i.keepKey) { return Verdict(level: .info, tag: "Kept") }
        if let until = ctx.snoozedUntil[i.id], until > now { return Verdict(level: .info, tag: "Snoozed") }

        let cost = i.batteryPerHour.map { $0 >= 1 ? String(format: " It's using about %.0f%% of your battery an hour.", $0) : "" } ?? ""
        let heavyFor = track.heavySince.map { now.timeIntervalSince($0) } ?? 0
        let idleServer: TimeInterval? = i.ports.isEmpty || i.connections > 0 ? nil
            : now.timeIntervalSince(track.lastConnection ?? max(track.firstSeen, i.started))

        switch i.kind {
        case .leftover:
            let by = i.session.map { " Left by “\($0)”." } ?? ""
            if i.connections > 0 { return Verdict(level: .info, tag: "In use") }
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

        case .appStarted:
            if let idle = idleServer, idle >= hour * scale {
                return Verdict(level: .info, tag: "Idle \(Describe.duration(idle))")
            }
            return Verdict(level: .none, tag: "")

        case .sessionJob, .claudeApp:
            return Verdict(level: .none, tag: "")

        case .simulator:
            let unused = now.timeIntervalSince(max(i.started, ctx.lastSimulatorUse ?? .distantPast))
            if unused >= 2 * hour * scale {
                return Verdict(level: .warn, tag: "Unused \(Describe.duration(unused))",
                               message: "\(i.title) has been running for \(Describe.duration(now.timeIntervalSince(i.started))) and hasn't been used in \(Describe.duration(unused)).\(cost)")
            }
            return Verdict(level: .none, tag: "")

        case .sleepHold:
            let held = now.timeIntervalSince(i.started)
            let idle = now.timeIntervalSince(ctx.lastClaudeWorking)
            guard held >= 2 * hour / ctx.speedup, idle >= 30 * min / ctx.speedup else { return Verdict(level: .none, tag: "") }
            if !ctx.onBattery { return Verdict(level: .info, tag: "No Claude work for \(Describe.duration(idle))") }
            return Verdict(level: .alarm, tag: "No Claude work for \(Describe.duration(idle))",
                           message: "Claude has kept your Mac awake for \(Describe.duration(held)), but no session has worked in \(Describe.duration(idle)). To stop this on battery, turn off Settings → Claude Code → “Keep awake on battery”.")
        }
    }
}
