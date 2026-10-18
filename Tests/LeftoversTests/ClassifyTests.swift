import Foundation
import Testing
@testable import Leftovers

private let home = "/Users/test"
private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

private func proc(_ pid: pid_t, _ ppid: pid_t, _ name: String, path: String? = nil,
                  args: [String]? = nil, cwd: String = "/", start: Date = t0) -> ProcRecord {
    ProcRecord(pid: pid, ppid: ppid, name: name, path: path ?? "/usr/bin/\(name)",
               args: args ?? [name], cwd: cwd, start: start)
}

private let app = proc(100, 1, "Claude", path: Classifier.claudeAppMain)
private let helper = proc(101, 100, "Claude Helper",
                          path: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper")
private let cli = proc(200, 101, "claude",
                       path: "\(home)/Library/Application Support/Claude/claude-code/2.1/x/claude.app/Contents/MacOS/claude",
                       cwd: "\(home)/Desktop/claude")
private let scratch = "/private/tmp/claude-501/-Users-test-Desktop-claude/9c0150a1-8c11-4092-906e-06938d938a8d/scratchpad/ad"

@Suite struct Grouping {
    let c = Classifier(home: home)

    @Test func stuckVideoJobIsALeftover() {
        // Today's case: build.sh orphaned to launchd, ffmpeg under it, both in a session scratchpad.
        let sh = proc(300, 1, "bash", args: ["bash", "build.sh"], cwd: scratch)
        let ff = proc(301, 300, "ffmpeg", args: ["ffmpeg", "-i", "/Users/test/Desktop/67.mov"], cwd: scratch)
        let g = c.group([app, helper, cli, sh, ff])
        #expect(g.leftovers.map { $0.map(\.pid) } == [[300, 301]])
        #expect(g.sessionJobs.isEmpty)
    }

    @Test func childOfARunningSessionIsNotALeftover() {
        let job = proc(400, 200, "zsh", cwd: "\(home)/Desktop/claude")
        let build = proc(401, 400, "swift-build", cwd: "\(home)/Desktop/claude/zom-zom")
        let g = c.group([app, helper, cli, job, build])
        #expect(g.leftovers.isEmpty)
        #expect(g.sessionJobs.map { $0.map(\.pid) } == [[400, 401]])
        #expect(g.sessions.map(\.pid) == [200])
    }

    @Test func terminalSessionsCountToo() {
        let term = proc(500, 499, "claude", path: "/opt/homebrew/bin/claude", cwd: "\(home)/Desktop/claude")
        let server = proc(501, 500, "node", args: ["node", "vite"], cwd: "\(home)/Desktop/claude/morse-waldo")
        let g = c.group([term, server])
        #expect(g.sessionJobs.map { $0.map(\.pid) } == [[501]])
    }

    @Test func previewServerBelongsToTheApp() {
        let server = proc(600, 100, "node", args: ["node", "vite"], cwd: "\(home)/Desktop/claude/pokemon-silverwind")
        let g = c.group([app, helper, server])
        #expect(g.appStarted.map { $0.map(\.pid) } == [[600]])
        #expect(g.claudeApp.map(\.pid) == [100, 101])
    }

    @Test func openedAppsAndSystemAreIgnored() {
        // An app built in a project folder and opened with `open` runs with "/" as its folder.
        let cat = proc(700, 1, "DesktopCat",
                       path: "\(home)/Desktop/claude/DesktopCatProject/DesktopCat.app/Contents/MacOS/DesktopCat")
        let daemon = proc(701, 1, "cloudd", path: "/System/Library/PrivateFrameworks/X/cloudd",
                          cwd: "\(home)/Desktop/claude")
        let unrelated = proc(702, 1, "python3", args: ["python3", "-m", "http.server"], cwd: "\(home)/Documents")
        #expect(c.group([cat, daemon, unrelated]).leftovers.isEmpty)
    }

    @Test func xcodesPythonInAProjectFolderIsStillCaught() {
        let py = proc(800, 1, "Python",
                      path: "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python",
                      args: ["Python", "-m", "http.server", "8000"], cwd: "\(home)/Desktop/claude/zom-zom")
        #expect(c.group([py]).leftovers.count == 1)
        #expect(Describe.title(for: py) == "Web server (Python)")
    }

    @Test func projectNames() {
        #expect(c.project(for: "\(home)/Desktop/claude/zom-zom/src") == "zom-zom")
        #expect(c.project(for: scratch) == "scratch files")
        #expect(c.project(for: "/") == nil)
    }
}

@Suite struct SessionMatching {
    func session(_ id: String, _ title: String, cwd: String = "\(home)/Desktop/claude",
                 from: TimeInterval, to: TimeInterval) -> SessionInfo {
        SessionInfo(cliSessionId: id, title: title, cwd: cwd, createdAt: t0.addingTimeInterval(from),
                    lastActivityAt: t0.addingTimeInterval(to), archived: false)
    }

    @Test func exactMatchFromScratchpadFolder() {
        var idx = SessionIndex()
        idx.sessions["9c0150a1-8c11-4092-906e-06938d938a8d"] = session("9c0150a1-8c11-4092-906e-06938d938a8d", "QuickNote ad", from: -100, to: 100)
        let hit = idx.match([proc(1, 1, "bash", cwd: scratch)])
        #expect(hit?.session.title == "QuickNote ad")
        #expect(hit?.guessed == false)
    }

    @Test func guessOnlyWhenOneSessionFits() {
        var idx = SessionIndex()
        idx.sessions["a"] = session("a", "Zom-Zom", cwd: "\(home)/Desktop/claude/zom-zom", from: -100, to: 100)
        idx.sessions["b"] = session("b", "Other", from: -100, to: 100)
        let p = proc(1, 1, "node", cwd: "\(home)/Desktop/claude/zom-zom")
        #expect(idx.match([p])?.session.title == "Zom-Zom")
        #expect(idx.match([p])?.guessed == true)

        // Two sessions in the same folder at the same time: don't guess.
        idx.sessions["c"] = session("c", "Zom-Zom 2", cwd: "\(home)/Desktop/claude/zom-zom", from: -50, to: 100)
        #expect(idx.match([p]) == nil)
    }

    @Test func noGuessForSessionsThatWereNotActive() {
        var idx = SessionIndex()
        idx.sessions["a"] = session("a", "Old", from: -10_000, to: -5_000)
        #expect(idx.match([proc(1, 1, "node", cwd: "\(home)/Desktop/claude")]) == nil)
    }
}

@Suite struct Wording {
    @Test func durations() {
        #expect(Describe.duration(30) == "under a minute")
        #expect(Describe.duration(12 * 60) == "12 min")
        #expect(Describe.duration(31 * 3600) == "31 h")
        #expect(Describe.duration(49 * 3600) == "2 days")
    }

    @Test func titles() {
        #expect(Describe.title(for: proc(1, 1, "ffmpeg")) == "Video encoding (ffmpeg)")
        #expect(Describe.title(for: proc(1, 1, "bash", args: ["bash", "build.sh"])) == "Script build.sh")
        #expect(Describe.title(for: proc(1, 1, "python3", args: ["python3", "-c", "x"])) == "Python one-liner")
    }
}
