import Foundation
import Testing
@testable import Leftovers

private let now = Date(timeIntervalSince1970: 1_792_000_000)
private let min = 60.0, hour = 3600.0

private func item(_ kind: ItemKind, id: String = "x", cpu: Double = 0, perHour: Double? = 0, average: Double = 0,
                  startedAgo: TimeInterval = 3 * hour, lastOutputAgo: TimeInterval? = nil,
                  ports: [UInt16] = [], connections: Int = 0) -> Item {
    Item(id: id, kind: kind, title: "Job", detail: "", command: "job", session: "Session", pids: [1],
         started: now.addingTimeInterval(-startedAgo), cpuPercent: cpu, batteryPerHour: perHour, ports: ports,
         connections: connections, lastOutput: lastOutputAgo.map { now.addingTimeInterval(-$0) },
         averageCpu: average, keepKey: "key-\(id)")
}

private func ctx(battery: Bool = false, simUsedAgo: TimeInterval? = nil, claudeIdle: TimeInterval = 0,
                 kept: Set<String> = [], snoozed: [String: Date] = [:]) -> RuleContext {
    RuleContext(now: now, onBattery: battery, lastSimulatorUse: simUsedAgo.map { now.addingTimeInterval(-$0) },
                lastClaudeWorking: now.addingTimeInterval(-claudeIdle), kept: kept, snoozedUntil: snoozed)
}

private func heavyTrack(for ago: TimeInterval, connectedAgo: TimeInterval? = nil) -> Track {
    Track(firstSeen: now.addingTimeInterval(-ago), heavySince: now.addingTimeInterval(-ago),
          lastConnection: connectedAgo.map { now.addingTimeInterval(-$0) })
}

@Suite struct Alarms {
    @Test func todaysStuckFfmpegIsRedRightAway() {
        // Seen for the first time, already 2 days old and busy its whole life, output untouched since.
        let i = item(.leftover, cpu: 250, perHour: 8, average: 240, startedAgo: 48 * hour, lastOutputAgo: 47 * hour)
        let t = Rules.updateTrack(nil, item: i, now: now)
        #expect(t.heavySince == i.started)
        let v = Rules.judge(i, track: t, ctx: ctx())
        #expect(v.level == .alarm)
        #expect(v.tag == "Looks stuck")
        #expect(v.message.contains("Left by “Session”"))
    }

    @Test func aLongExportStillWritingIsNotStuck() {
        let i = item(.leftover, cpu: 200, perHour: 6, lastOutputAgo: 5)
        #expect(Rules.judge(i, track: heavyTrack(for: 2 * hour), ctx: ctx()).level == .warn)   // forgotten, not stuck
    }

    @Test func briefBurstsDontCount() {
        let i = item(.leftover, cpu: 90, perHour: 3)
        #expect(Rules.judge(i, track: heavyTrack(for: 4 * min), ctx: ctx()).level == .info)
        #expect(Rules.judge(i, track: heavyTrack(for: 12 * min), ctx: ctx()).level == .warn)
    }

    @Test func batteryHalvesTheWait() {
        let i = item(.leftover, cpu: 90, perHour: 3)
        #expect(Rules.judge(i, track: heavyTrack(for: 6 * min), ctx: ctx(battery: false)).level == .info)
        #expect(Rules.judge(i, track: heavyTrack(for: 6 * min), ctx: ctx(battery: true)).level == .warn)
    }

    @Test func aBurstAfterQuietRestartsTheClock() {
        let i = item(.leftover, cpu: 90, perHour: 3)
        let quiet = item(.leftover, cpu: 0, perHour: 0)
        var t = Rules.updateTrack(nil, item: i, now: now.addingTimeInterval(-20 * min))
        t = Rules.updateTrack(t, item: quiet, now: now.addingTimeInterval(-5 * min))
        t = Rules.updateTrack(t, item: i, now: now)
        #expect(t.heavySince == now)
    }

    @Test func busyJobsOfARunningSessionNeverAlarm() {
        let i = item(.sessionJob, cpu: 400, perHour: 15, average: 400, startedAgo: 9 * hour, lastOutputAgo: 9 * hour)
        #expect(Rules.judge(i, track: heavyTrack(for: 9 * hour), ctx: ctx()).level == .none)
    }

    @Test func aServerSomeoneIsUsingIsLeftAlone() {
        let i = item(.leftover, cpu: 30, perHour: 2, ports: [5173], connections: 2)
        #expect(Rules.judge(i, track: heavyTrack(for: 3 * hour), ctx: ctx()).tag == "In use")
    }

    @Test func idleServerIsMenuOnly() {
        let i = item(.appStarted, ports: [5173])
        let v = Rules.judge(i, track: Track(firstSeen: now.addingTimeInterval(-2 * hour)), ctx: ctx())
        #expect(v.level == .info)
        #expect(v.tag == "Idle 2 h")
        let recent = Track(firstSeen: now.addingTimeInterval(-2 * hour), lastConnection: now.addingTimeInterval(-10 * min))
        #expect(Rules.judge(i, track: recent, ctx: ctx()).level == .none)
    }

    @Test func simulatorsYouUseAreFine() {
        let sim = item(.simulator, perHour: 6, startedAgo: 31 * hour)
        let t = Track(firstSeen: now)
        #expect(Rules.judge(sim, track: t, ctx: ctx(simUsedAgo: 10 * min)).level == .none)
        let v = Rules.judge(sim, track: t, ctx: ctx(simUsedAgo: 5 * hour))
        #expect(v.level == .warn)
        #expect(v.tag == "Unused 5 h")
        #expect(Rules.judge(item(.simulator, startedAgo: 30 * min), track: t, ctx: ctx()).level == .none)
    }

    @Test func claudeSleepHold() {
        let hold = item(.sleepHold, perHour: nil, startedAgo: 55 * hour)
        let t = Track(firstSeen: now)
        #expect(Rules.judge(hold, track: t, ctx: ctx(battery: true, claudeIdle: 5 * min)).level == .none)   // working
        #expect(Rules.judge(hold, track: t, ctx: ctx(battery: false, claudeIdle: 3 * hour)).level == .info) // plugged in
        let v = Rules.judge(hold, track: t, ctx: ctx(battery: true, claudeIdle: 3 * hour))
        #expect(v.level == .alarm)
        #expect(v.message.contains("Keep awake on battery"))
    }

    @Test func keepAndSnooze() {
        let i = item(.leftover, cpu: 250, perHour: 8, lastOutputAgo: 47 * hour)
        let t = heavyTrack(for: 48 * hour)
        #expect(Rules.judge(i, track: t, ctx: ctx(kept: ["key-x"])).tag == "Kept")
        #expect(Rules.judge(i, track: t, ctx: ctx(snoozed: ["x": now.addingTimeInterval(600)])).tag == "Snoozed")
        #expect(Rules.judge(i, track: t, ctx: ctx(snoozed: ["x": now.addingTimeInterval(-1)])).level == .alarm)
    }
}
