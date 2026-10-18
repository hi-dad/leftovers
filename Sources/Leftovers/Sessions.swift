import Foundation

/// The Claude app's record of its sessions, so a process can be named by the session that started it.
/// Read-only: these files belong to the Claude app.
struct SessionIndex {
    var sessions: [String: SessionInfo] = [:]   // by cliSessionId

    static let folder = NSHomeDirectory() + "/Library/Application Support/Claude/claude-code-sessions"

    static func load(from folder: String = folder) -> SessionIndex {
        var idx = SessionIndex()
        guard let e = FileManager.default.enumerator(atPath: folder) else { return idx }
        for case let rel as String in e where rel.hasSuffix(".json") && (rel as NSString).lastPathComponent.hasPrefix("local_") {
            guard let data = FileManager.default.contents(atPath: folder + "/" + rel),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["cliSessionId"] as? String else { continue }
            func date(_ k: String) -> Date {
                Date(timeIntervalSince1970: ((obj[k] as? Double) ?? 0) / 1000)
            }
            idx.sessions[id] = SessionInfo(
                cliSessionId: id,
                title: (obj["title"] as? String) ?? "Untitled session",
                cwd: (obj["cwd"] as? String) ?? "",
                createdAt: date("createdAt"),
                lastActivityAt: max(date("lastActivityAt"), date("latestUserFrameAt")),
                archived: (obj["isArchived"] as? Bool) ?? false)
        }
        return idx
    }

    private static let uuid = try! NSRegularExpression(
        pattern: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", options: [.caseInsensitive])

    /// The session that started this family. Exact when a session id appears in its folder or
    /// arguments (Claude's scratchpad folders carry it); otherwise a guess from folder + start time.
    func match(_ family: [ProcRecord]) -> (session: SessionInfo, guessed: Bool)? {
        for p in family {
            for s in [p.cwd] + p.args {
                let range = NSRange(s.startIndex..., in: s)
                for m in Self.uuid.matches(in: s, range: range) {
                    if let r = Range(m.range, in: s), let hit = sessions[s[r].lowercased()] { return (hit, false) }
                }
            }
        }
        guard let root = family.first, !root.cwd.isEmpty else { return nil }
        let start = root.start
        let candidates = sessions.values.filter {
            !$0.cwd.isEmpty && (root.cwd == $0.cwd || root.cwd.hasPrefix($0.cwd + "/"))
                && $0.createdAt <= start && start <= $0.lastActivityAt.addingTimeInterval(15 * 60)
        }
        // Only the deepest matching folder counts, and only when exactly one session was active
        // then: several sessions in the same folder would make the name a coin toss.
        guard let deepest = candidates.map(\.cwd.count).max() else { return nil }
        let best = candidates.filter { $0.cwd.count == deepest }
        return best.count == 1 ? (best[0], true) : nil
    }
}
