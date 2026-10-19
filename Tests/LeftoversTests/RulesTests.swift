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
                 kept: Set<String> = []) -> RuleContext {
    RuleContext(now: now, onBattery: battery, lastSimulatorUse: simUsedAgo.map { now.addingTimeInterval(-$0) },
                lastClaudeWorking: now.addingTimeInterval(-claudeIdle), kept: kept)
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
        let recent = Track(firstSeen: now.addingTimeInterval(-2 * hour), lastConnection: now.addingTimeInterval(-5 * min))
        #expect(Rules.judge(i, track: recent, ctx: ctx()).level == .none)
    }

    @Test func simulatorsYouUseAreFine() {
        let sim = item(.simulator, perHour: 6, startedAgo: 31 * hour)
        let t = Track(firstSeen: now)
        #expect(Rules.judge(sim, track: t, ctx: ctx(simUsedAgo: 10 * min)).level == .none)
        let v = Rules.judge(sim, track: t, ctx: ctx(simUsedAgo: 5 * hour))
        #expect(v.level == .warn)
        #expect(v.tag == "Unused 5 h")
        #expect(Rules.judge(item(.simulator, startedAgo: 20 * min), track: t, ctx: ctx()).level == .none)
    }


    @Test func keep() {
        let i = item(.leftover, cpu: 250, perHour: 8, lastOutputAgo: 47 * hour)
        let t = heavyTrack(for: 48 * hour)
        #expect(Rules.judge(i, track: t, ctx: ctx(kept: ["key-x"])).tag == "Kept")
    }
}

@Suite struct PlainWords {
    func leftover(_ noun: String, tag: String, project: String? = nil, session: String? = nil, ports: [UInt16] = []) -> Item {
        var i = item(.leftover, ports: ports)
        i.noun = noun; i.project = project; i.session = session
        i.verdict = Verdict(level: .warn, tag: tag)
        return i
    }

    @Test func summaries() {
        #expect(Describe.summary(leftover("Python script", tag: "Looks stuck", project: "zom-zom")) == "Python script stuck in zom-zom")
        #expect(Describe.summary(leftover("Video export", tag: "Looks stuck", project: "scratch files", session: "QuickNote ad"))
                == "Video export stuck from your “QuickNote ad” chat")
        #expect(Describe.summary(leftover("Node script", tag: "Forgotten", project: "morse-waldo")) == "Node script still running in morse-waldo")
        #expect(Describe.summary(leftover("Test website", tag: "Left behind", project: "zom-zom", ports: [8000])) == "Test website for zom-zom left running")
        var sim = item(.simulator); sim.noun = "iPhone simulator"; sim.apps = ["StoryboardAR"]
        #expect(Describe.summary(sim) == "iPhone simulator running StoryboardAR")
    }

    @Test func advice() {
        #expect(Describe.advice(leftover("Python script", tag: "Looks stuck"))! == ("Safe to stop", "it isn't making progress"))
        #expect(Describe.advice(leftover("Python script", tag: "Forgotten"))! == ("Safe to stop", "its Claude chat already finished"))
        #expect(Describe.advice(leftover("App build", tag: "Forgotten"))!.label == "Stopping")
        #expect(Describe.advice(leftover("Test website", tag: "Left behind", ports: [8000]))!.text == "closes the test website until it's restarted")
    }
}

@Suite struct NewChecks {
    @Test func androidLikeSimulators() {
        let emu = item(.android, perHour: 5, startedAgo: 5 * hour)
        let t = Track(firstSeen: now)
        #expect(Rules.judge(emu, track: t, ctx: ctx()).level == .warn)
        var c = ctx(); c.lastAndroidUse = now.addingTimeInterval(-10 * min)
        #expect(Rules.judge(emu, track: t, ctx: c).level == .none)
    }

    @Test func claudePreviewOnlyWhenNothingIsWorking() {
        let busy = item(.claudePreview, cpu: 40, perHour: 3)
        let t = heavyTrack(for: 20 * min)
        #expect(Rules.judge(busy, track: t, ctx: ctx(claudeIdle: 1 * min)).level == .none)   // Claude is replying
        #expect(Rules.judge(busy, track: t, ctx: ctx(claudeIdle: 30 * min)).level == .warn)
        #expect(Rules.judge(busy, track: heavyTrack(for: 2 * min), ctx: ctx(claudeIdle: 30 * min)).level == .none)
    }

    @Test func spotlightNeedsToLast() {
        var s = item(.spotlight, cpu: 60, perHour: nil); s.apps = ["~/Desktop/claude/zom-zom/node_modules"]
        #expect(Rules.judge(s, track: heavyTrack(for: 5 * min), ctx: ctx()).level == .none)
        let v = Rules.judge(s, track: heavyTrack(for: 20 * min), ctx: ctx())
        #expect(v.level == .warn)
        #expect(v.message.contains("zom-zom/node_modules"))
    }

    @Test func tabsOnlyWhenChromeIsIdle() {
        let tab = item(.browserTab, cpu: 30, perHour: nil)
        let longOpen = Track(firstSeen: now.addingTimeInterval(-2 * hour), heavySince: now.addingTimeInterval(-hour))
        var used = ctx(); used.lastChromeUse = now.addingTimeInterval(-5 * min)
        #expect(Rules.judge(tab, track: longOpen, ctx: used).level == .none)
        var idle = ctx(); idle.lastChromeUse = now.addingTimeInterval(-2 * hour)
        #expect(Rules.judge(tab, track: longOpen, ctx: idle).level == .warn)
        let quiet = item(.browserTab, cpu: 1, perHour: nil)
        #expect(Rules.judge(quiet, track: Track(firstSeen: now.addingTimeInterval(-2 * hour)), ctx: idle).tag == "Open tab")
    }

    @Test func pagesThatCount() {
        let folders = ["/Users/test/Desktop/claude"]
        #expect(Extras.isClaudePage("http://localhost:5173/", folders: folders))
        #expect(Extras.isClaudePage("http://127.0.0.1:8000/index.html", folders: folders))
        #expect(Extras.isClaudePage("file:///Users/test/Desktop/claude/morse-waldo/index.html", folders: folders))
        #expect(!Extras.isClaudePage("https://github.com/", folders: folders))
        #expect(!Extras.isClaudePage("file:///Users/test/Documents/a.html", folders: folders))
    }

    @Test func everyRowYouCanActOnSaysWhatHappens() {
        for kind in ItemKind.allCases where kind != .sessionJob {
            var i = item(kind); i.noun = kind == .android ? "Android emulator" : "Python script"
            #expect(Describe.advice(i) != nil, "\(kind)")
        }
        var site = item(.leftover, ports: [8000]); site.noun = "Test website"
        #expect(Describe.advice(site)?.text == "closes the test website until it's restarted")
    }
}

@Suite struct Folders {
    @Test func workFoldersSkipHomeAndNested() {
        var idx = SessionIndex()
        let home = NSHomeDirectory()
        for (id, cwd) in [("a", home + "/Desktop/claude"), ("b", home + "/Desktop/claude/zom-zom"), ("c", home), ("d", home + "/Desktop/Other")] {
            idx.sessions[id] = SessionInfo(cliSessionId: id, title: id, cwd: cwd, createdAt: now, lastActivityAt: now, archived: false)
        }
        #expect(idx.workFolders == [home + "/Desktop/Other", home + "/Desktop/claude"])
    }
}

@Suite struct ChatHelpers {
    func helper(cpu: Double, busy: Bool, idleFor: TimeInterval) -> Item {
        var h = item(.chatHelper, cpu: cpu, perHour: cpu / 10)
        h.title = "Project ideas"; h.busy = busy
        h.idleSince = busy ? nil : now.addingTimeInterval(-idleFor)
        return h
    }

    @Test func busyChatsAreLeftAlone() {
        #expect(Rules.judge(helper(cpu: 90, busy: true, idleFor: 0), track: heavyTrack(for: hour), ctx: ctx()).level == .none)
    }

    @Test func idleButSpinningIsStuck() {
        let v = Rules.judge(helper(cpu: 100, busy: false, idleFor: 2 * hour), track: heavyTrack(for: 30 * min), ctx: ctx())
        #expect(v.level == .warn)
        #expect(Describe.summary({ var h = helper(cpu: 100, busy: false, idleFor: 0); h.verdict = v; return h }()) == "Claude chat stuck in a loop: “Project ideas”")
        // Just finished a reply: a little CPU right after isn't "stuck".
        #expect(Rules.judge(helper(cpu: 100, busy: false, idleFor: 2 * min), track: heavyTrack(for: 30 * min), ctx: ctx()).level < .warn)
    }

    @Test func oldQuietHelpersAreLeftToClaude() {
        // Old quiet chats are never flagged, however old (only a pile-up or a loop is).
        #expect(Rules.judge(helper(cpu: 0, busy: false, idleFor: 30 * hour), track: Track(firstSeen: now), ctx: ctx()).level == .none)
        #expect(Rules.helperPileup == 15)
    }

    @Test func pileup() {
        var pile = item(.helperPileup); pile.title = "150 chat helpers"; pile.memoryMB = 15_000
        #expect(Rules.judge(pile, track: Track(firstSeen: now), ctx: ctx()).level == .warn)
    }

    @Test func readsHelperStatusFiles() throws {
        let dir = NSTemporaryDirectory() + "leftovers-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let json = #"{"pid": 4242, "name": "Snail House", "status": "idle", "statusUpdatedAt": 1792289418920, "entrypoint": "claude-desktop"}"#
        try json.write(toFile: dir + "/4242.json", atomically: true, encoding: .utf8)
        try "secret".write(toFile: dir + "/4242.abc.key", atomically: true, encoding: .utf8)
        let h = HelperInfo.load(from: dir)
        #expect(h.count == 1)
        #expect(h[4242]?.name == "Snail House")
        #expect(h[4242]?.busy == false)
        #expect(h[4242]?.fromApp == true)
    }
}

@Suite struct Subheaders {
    @Test func oneStyleForEveryRow() {
        var stuck = item(.leftover, startedAgo: 48 * hour, lastOutputAgo: 47 * hour)
        stuck.noun = "Video export"
        #expect(Rules.status(stuck, track: Track(firstSeen: now), ctx: ctx()) == "Running 2 days · last change 47 h ago")

        let site = item(.appStarted, startedAgo: 3 * hour, ports: [5173])
        let visited = Track(firstSeen: now.addingTimeInterval(-3 * hour), lastConnection: now.addingTimeInterval(-2 * hour))
        #expect(Rules.status(site, track: visited, ctx: ctx()) == "Running 3 h · last visit 2 h ago")
        #expect(Rules.status(site, track: Track(firstSeen: now), ctx: ctx()) == "Running 3 h · no visits yet")

        let sim = item(.simulator, startedAgo: 31 * hour)
        #expect(Rules.status(sim, track: Track(firstSeen: now), ctx: ctx(simUsedAgo: 30 * hour)) == "Running 31 h · last used 30 h ago")

        var chat = item(.chatHelper); chat.idleSince = now.addingTimeInterval(-3 * hour)
        #expect(Rules.status(chat, track: heavyTrack(for: 20 * min), ctx: ctx()) == "Busy 20 min · last message 3 h ago")
        chat.busy = true
        #expect(Rules.status(chat, track: heavyTrack(for: 20 * min), ctx: ctx()) == "Working now")


        var spot = item(.spotlight); spot.apps = ["a", "b", "c"]
        #expect(Rules.status(spot, track: heavyTrack(for: 20 * min), ctx: ctx()) == "Busy 20 min · 3 build folders changed")
    }

    @Test func inUseVersusInactive() {
        let sim = item(.simulator, startedAgo: hour)
        #expect(Rules.judge(sim, track: Track(firstSeen: now), ctx: ctx(simUsedAgo: 5 * min)).level == .none)   // in use
        #expect(Rules.judge(sim, track: Track(firstSeen: now), ctx: ctx(simUsedAgo: 45 * min)).level == .info)  // inactive
        let visited = item(.leftover, ports: [8000], connections: 1)
        #expect(Rules.judge(visited, track: Track(firstSeen: now), ctx: ctx()).level == .none)
    }
}

@Suite struct Icons {
    @Test func iconsShowTheKindOfThing() {
        var stuck = item(.leftover); stuck.noun = "Video export"; stuck.verdict = Verdict(level: .alarm, tag: "Looks stuck")
        #expect(Describe.icon(stuck) == "arrow.triangle.2.circlepath")   // loops share one icon
        stuck.verdict = Verdict(level: .warn, tag: "Forgotten")
        #expect(Describe.icon(stuck) == "film")
        var build = item(.leftover); build.noun = "App build"
        #expect(Describe.icon(build) == "hammer")
        #expect(Describe.icon(item(.appStarted, ports: [5173])) == "globe")
        #expect(Describe.icon(item(.simulator)) == "iphone")
        var chat = item(.chatHelper); chat.verdict = Verdict(level: .warn, tag: "Stuck")
        #expect(Describe.icon(chat) == "arrow.triangle.2.circlepath")
    }
}

@Suite struct Checks {
    @Test func everyRowBelongsToACheckYouCanSwitchOff() {
        var site = item(.leftover, ports: [8000]); site.noun = "Test website"
        #expect(Check.of(site) == .websites)
        var script = item(.leftover); script.noun = "Python script"
        #expect(Check.of(script) == .leftovers)
        #expect(Check.of(item(.android)) == .devices)
        #expect(Check.of(item(.spotlight)) == .spotlight)
        // Every kind of row maps to a check (websites are told apart by their port), and every check is used.
        #expect(Set(ItemKind.allCases.map { Check.of(item($0)) } + [Check.of(site)]) == Set(Check.allCases))
    }
}
