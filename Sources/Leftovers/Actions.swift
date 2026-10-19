import AppKit
import Foundation

/// Stop and Keep. Nothing here runs without a click.
extension Monitor {
    func canStop(_ i: Item) -> Bool { [.leftover, .appStarted, .simulator, .android, .chatHelper].contains(i.kind) }

    func stop(_ i: Item) {
        switch i.kind {
        case .simulator:
            let udid = String(i.id.dropFirst("sim-".count))
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                p.arguments = ["simctl", "shutdown", udid]
                try? p.run(); p.waitUntilExit()
                DispatchQueue.main.async { self.scan() }
            }
        case .leftover, .appStarted, .android, .chatHelper:
            let members = Array(zip(i.pids, i.startTimes))
            DispatchQueue.global(qos: .userInitiated).async {
                // Only signal a pid if it is still the same process (pids get reused).
                func alive() -> [pid_t] {
                    members.filter { ProcScan.startTime($0.0) == $0.1 }.map(\.0)
                }
                // Ask politely first (root first, so a script can't start new work), then insist.
                for pid in alive() { kill(pid, SIGTERM) }
                for _ in 0..<10 where !alive().isEmpty { Thread.sleep(forTimeInterval: 0.5) }
                for pid in alive() { kill(pid, SIGKILL) }
                Thread.sleep(forTimeInterval: 0.3)
                DispatchQueue.main.async { self.scan() }
            }
        default:
            break
        }
    }

    func keep(_ i: Item) {
        kept[i.keepKey] = i.kind == .simulator ? i.title + " (until it shuts down)" : [i.title, i.project].compactMap { $0 }.joined(separator: " · ")
        rejudge()
    }

    /// "Don't warn again": switches that whole check off (same as unticking it in Settings → Watch for).
    func switchOff(_ i: Item) {
        offChecks.insert(Check.of(i))
        scan()
    }

    func openSpotlightSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Spotlight-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: (path as NSString).expandingTildeInPath)])
    }

    func openInBrowser(_ i: Item) {
        guard let port = i.ports.first, let url = URL(string: "http://localhost:\(port)") else { return }
        NSWorkspace.shared.open(url)
    }


    func openClaude() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Claude.app"),
                                           configuration: NSWorkspace.OpenConfiguration())
    }

    /// Re-applies the rules without rescanning (after Keep).
    private func rejudge() {
        let raw = items
        let tracksBefore = tracks
        judge(raw, facts: Facts(), now: Date())
        tracks = tracksBefore
    }
}
