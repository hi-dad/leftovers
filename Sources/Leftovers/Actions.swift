import AppKit
import Foundation

/// Stop, Keep and Snooze. Nothing here runs without a click.
extension Monitor {
    func canStop(_ i: Item) -> Bool { [.leftover, .appStarted, .simulator].contains(i.kind) }

    func stop(_ i: Item) {
        switch i.kind {
        case .simulator:
            let udid = String(i.id.dropFirst("sim-".count))
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                p.arguments = ["simctl", "shutdown", udid]
                try? p.run(); p.waitUntilExit()
                DispatchQueue.main.async { self.logStop(i); self.scan() }
            }
        case .leftover, .appStarted:
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
                DispatchQueue.main.async { self.logStop(i); self.scan() }
            }
        default:
            break
        }
    }

    func keep(_ i: Item) {
        kept[i.keepKey] = i.kind == .simulator ? i.title + " (until it shuts down)" : [i.title, i.project].compactMap { $0 }.joined(separator: " · ")
        rejudge()
    }

    func unkeep(_ key: String) {
        kept[key] = nil
        rejudge()
    }

    func snooze(_ i: Item, hours: Double = 1) {
        snoozedUntil[i.id] = Date().addingTimeInterval(hours * 3600)
        rejudge()
    }

    func openClaude() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Claude.app"),
                                           configuration: NSWorkspace.OpenConfiguration())
    }

    /// Re-applies the rules without rescanning (after Keep/Snooze).
    private func rejudge() {
        let raw = items
        let tracksBefore = tracks
        judge(raw, facts: Facts(), now: Date())
        tracks = tracksBefore
    }

    // MARK: savings log (shown as "battery saved" in the menu)

    struct StopRecord: Codable { var at: Date; var title: String; var watts: Double }

    var stopLog: [StopRecord] {
        get {
            guard let d = UserDefaults.standard.data(forKey: "stopLog") else { return [] }
            return (try? JSONDecoder().decode([StopRecord].self, from: d)) ?? []
        }
        set {
            let recent = newValue.filter { $0.at > Date().addingTimeInterval(-90 * 86400) }
            UserDefaults.standard.set(try? JSONEncoder().encode(recent), forKey: "stopLog")
        }
    }

    private func logStop(_ i: Item) {
        stopLog.append(StopRecord(at: Date(), title: i.title, watts: i.watts))
        objectWillChange.send()
    }
}
