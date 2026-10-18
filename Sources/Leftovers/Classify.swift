import Foundation

/// Sorts the process table into Claude-related families. Pure: no system calls, so it is fully tested.
struct Grouping {
    /// Families whose Claude session is gone (re-parented to launchd). Root first.
    var leftovers: [[ProcRecord]] = []
    /// Families started by a Claude session that is still running. Root (a direct child of the session) first.
    var sessionJobs: [[ProcRecord]] = []
    /// Families started by the Claude app outside a session (preview servers etc.). Root first.
    var appStarted: [[ProcRecord]] = []
    /// The Claude app's own processes (main app + helpers).
    var claudeApp: [ProcRecord] = []
    /// Running Claude Code processes (one per session turn, or per terminal session).
    var sessions: [ProcRecord] = []
}

struct Classifier {
    var home: String
    /// Folders whose stray processes count as Claude's (where Claude builds things).
    var watchedFolders: [String]

    init(home: String = NSHomeDirectory(), watchedFolders: [String]? = nil) {
        self.home = home
        self.watchedFolders = watchedFolders ?? Self.savedFolders(home: home)
    }

    /// Folders chosen in Settings (default: ~/Desktop/claude, where Claude builds your projects).
    static func savedFolders(home: String = NSHomeDirectory()) -> [String] {
        (UserDefaults.standard.array(forKey: "watchedFolders") as? [String]) ?? [home + "/Desktop/claude"]
    }

    static let claudeAppBundle = "/Applications/Claude.app/"
    static let claudeAppMain = "/Applications/Claude.app/Contents/MacOS/Claude"

    func isClaudeApp(_ p: ProcRecord) -> Bool { p.path.hasPrefix(Self.claudeAppBundle) }

    func isClaudeCode(_ p: ProcRecord) -> Bool {
        if p.path.hasSuffix("/MacOS/claude") && p.path.contains("claude-code") { return true }
        if p.name == "claude" && !isClaudeApp(p) { return true }
        return p.args.prefix(3).contains { $0.contains("@anthropic-ai/claude-code") }
    }

    /// True when the process plainly belongs to Claude's working areas.
    func isClaudeish(_ p: ProcRecord) -> Bool {
        let places = [p.cwd, p.path] + p.args
        return places.contains { s in
            s.contains("/tmp/claude-") || s.contains(home + "/.claude/")
                || watchedFolders.contains { s == $0 || s.hasPrefix($0 + "/") }
        }
    }

    /// System parts and opened apps are never leftovers: you can see and quit apps yourself.
    /// (An app opened from Finder/Dock/`open` runs with "/" as its folder; a tool such as
    /// Xcode's Python, which also lives inside an .app, runs in the folder it was started from.)
    func isAppOrSystem(_ p: ProcRecord) -> Bool {
        let roots = ["/System/", "/usr/libexec/", "/usr/sbin/"]
        return roots.contains { p.path.hasPrefix($0) } || (p.path.contains(".app/Contents/MacOS/") && p.cwd == "/")
    }

    func group(_ procs: [ProcRecord]) -> Grouping {
        var byPid: [pid_t: ProcRecord] = [:]
        var children: [pid_t: [pid_t]] = [:]
        for p in procs { byPid[p.pid] = p }
        for p in procs where p.pid != p.ppid { children[p.ppid, default: []].append(p.pid) }
        for k in children.keys { children[k]!.sort() }

        func family(_ root: pid_t) -> [ProcRecord] {
            var out: [ProcRecord] = [], stack = [root]
            while let pid = stack.popLast() {
                if let p = byPid[pid] { out.append(p) }
                stack.append(contentsOf: (children[pid] ?? []).reversed())
            }
            return out
        }

        var g = Grouping()
        var claimed = Set<pid_t>()

        // 1. Claude Code processes, wherever they run (Claude app or a terminal), and what they started.
        g.sessions = procs.filter(isClaudeCode).sorted { $0.pid < $1.pid }
        let sessionPids = Set(g.sessions.map(\.pid))
        for s in g.sessions {
            claimed.insert(s.pid)
            for child in children[s.pid] ?? [] where !sessionPids.contains(child) {
                let fam = family(child).filter { !sessionPids.contains($0.pid) }
                guard !fam.isEmpty, !claimed.contains(child) else { continue }
                fam.forEach { claimed.insert($0.pid) }
                g.sessionJobs.append(fam)
            }
        }

        // 2. The Claude app, its helpers, and anything else it launched.
        if let app = procs.first(where: { $0.path == Self.claudeAppMain }) {
            for p in family(app.pid) where !claimed.contains(p.pid) {
                if isClaudeApp(p) {
                    g.claudeApp.append(p); claimed.insert(p.pid)
                } else if let parent = byPid[p.ppid], isClaudeApp(parent) {
                    let fam = family(p.pid).filter { !claimed.contains($0.pid) }
                    fam.forEach { claimed.insert($0.pid) }
                    if !fam.isEmpty { g.appStarted.append(fam) }
                }
            }
        }

        // 3. Orphans: handed to launchd after the session that started them ended.
        for p in procs.sorted(by: { $0.pid < $1.pid })
        where p.ppid == 1 && !claimed.contains(p.pid) && !isAppOrSystem(p) && isClaudeish(p) {
            let fam = family(p.pid).filter { !claimed.contains($0.pid) }
            fam.forEach { claimed.insert($0.pid) }
            g.leftovers.append(fam)
        }
        return g
    }

    /// Short project name for a working folder ("zom-zom", "scratch files", …).
    func project(for cwd: String) -> String? {
        if cwd.contains("/tmp/claude-") { return "scratch files" }
        for root in watchedFolders where cwd.hasPrefix(root + "/") {
            return String(cwd.dropFirst(root.count + 1).split(separator: "/").first ?? "")
        }
        if cwd.isEmpty || cwd == "/" { return nil }
        return (cwd as NSString).lastPathComponent
    }
}

/// Plain-language names for common commands.
enum Describe {
    static func title(for p: ProcRecord) -> String {
        let a = p.args.map { ($0 as NSString).lastPathComponent }
        let name = p.name.lowercased()
        let joined = p.args.joined(separator: " ")
        switch true {
        case name == "ffmpeg": return "Video encoding (ffmpeg)"
        case joined.contains("http.server"): return "Web server (Python)"
        case joined.contains("vite"): return "Dev server (Vite)"
        case joined.contains("next dev") || joined.contains("next-server"): return "Dev server (Next.js)"
        case joined.contains("expo start") || joined.contains("metro"): return "Dev server (Expo)"
        case joined.contains("webpack"): return "Dev server (webpack)"
        case a.contains("npm") || a.contains("npx"): return "npm " + p.args.dropFirst(a.firstIndex(of: "npm").map { $0 + 1 } ?? 1).prefix(2).joined(separator: " ")
        case name == "xcodebuild": return "Xcode build"
        case name.hasPrefix("swift-build") || joined.contains("swift build"): return "Swift build"
        case name == "swift-frontend": return "Swift compiler"
        case name.hasPrefix("python"): return "Python " + (scriptName(p) ?? "script")
        case name == "node": return "Node " + (scriptName(p) ?? "script")
        case ["bash", "zsh", "sh"].contains(name): return "Script " + (scriptName(p) ?? "(shell)")
        case name == "caffeinate": return "caffeinate (keeps Mac awake)"
        default: return p.name
        }
    }

    /// What it is, in everyday words, for the one-line summary.
    static func noun(for p: ProcRecord) -> String {
        let name = p.name.lowercased(), joined = p.args.joined(separator: " ")
        switch true {
        case name == "ffmpeg": return "Video export"
        case ["http.server", "vite", "next dev", "next-server", "expo start", "metro", "webpack"].contains(where: joined.contains):
            return "Test website"
        case name.hasPrefix("python"): return "Python script"
        case name == "node": return "Node script"
        case ["bash", "zsh", "sh"].contains(name): return "Script"
        case name == "xcodebuild" || name.hasPrefix("swift"): return "App build"
        case name == "caffeinate": return "Keep-awake command"
        default: return "Program (\(p.name))"
        }
    }

    /// The one-line summary shown on each row ("Python script stuck in zom-zom").
    static func summary(_ i: Item) -> String {
        var place = ""
        if let p = i.project, p != "scratch files" { place = " in \(p)" }
        else if let s = i.session { place = " from your “\(s)” chat" }
        switch i.kind {
        case .simulator:
            return i.noun + (i.apps.isEmpty ? " running" : " running " + ListFormatter.localizedString(byJoining: i.apps))
        case .sleepHold:
            return "Claude is keeping your Mac awake for no reason"
        case .android:
            return "Android emulator running (\(i.title))"
        case .claudePreview:
            return "Something open in the Claude app keeps animating"
        case .spotlight:
            return "Spotlight is indexing Claude's build files"
        case .cloudSync:
            return "Cloud sync is uploading Claude's build files"
        case .browserTab:
            return "Chrome tab still open: \(i.title)" + (i.project.map { " (\($0))" } ?? "")
        case .chatHelper:
            return i.verdict.tag == "Stuck" ? "Claude chat stuck: “\(i.title)”" : "“\(i.title)”"
        case .helperPileup:
            return "Too many Claude chats loaded (\(i.apps.count))"
        case .chromeExtension:
            return "A Chrome extension keeps working in the background"
        case .appStarted, .sessionJob:
            return i.ports.isEmpty ? i.noun + place : "Test website" + (i.project.map { " for \($0)" } ?? "")
        case .leftover:
            if !i.ports.isEmpty { return "Test website" + (i.project.map { $0 == "scratch files" ? place : " for \($0)" } ?? place) + " left running" }
            switch i.verdict.tag {
            case "Looks stuck": return "\(i.noun) stuck\(place)"
            case "Forgotten": return "\(i.noun) still running\(place)"
            default: return "\(i.noun) left running\(place)"
            }
        }
    }

    /// The second line: why it's listed, in plain words.
    static func reason(_ i: Item, now: Date = Date()) -> String {
        let tag = i.verdict.tag
        if i.kind == .chatHelper {
            if i.busy { return "Working now" }
            if tag == "Stuck" { return "Busy although the chat is idle" }
            if tag == "Kept" { return "You chose to keep this" }
            let idle = duration(now.timeIntervalSince(i.idleSince ?? i.started))
            return "Idle for \(idle)"
        }
        switch true {
        case tag == "Kept": return "You chose to keep this running"
        case tag == "In use": return "Someone has it open, so it's fine"
        case tag == "Looks stuck":
            return "Working hard, but no progress in \(duration(now.timeIntervalSince(i.lastOutput ?? i.started)))"
        case tag == "Forgotten": return "Claude finished, but this kept going"
        case tag.hasPrefix("Idle "): return "Nobody has opened it in \(tag.dropFirst(5))"
        case tag.hasPrefix("Unused "): return "Not used in \(tag.dropFirst(7))"
        case tag.hasPrefix("No Claude work"): return "Claude hasn't done anything in \(tag.dropFirst("No Claude work for ".count))"
        case tag == "Busy preview": return "Probably a preview or artifact that's still playing"
        case tag == "Indexing", tag == "Syncing":
            return i.apps.prefix(2).map { ($0 as NSString).lastPathComponent == $0 ? $0 : (($0 as NSString).deletingLastPathComponent as NSString).lastPathComponent + "/" + ($0 as NSString).lastPathComponent }.joined(separator: ", ") + (i.apps.count > 2 ? " and \(i.apps.count - 2) more" : "")
        case tag == "Working": return "Working now"
        case tag == "Stuck": return "Busy although the chat is idle"
        case tag == "Pile-up": return String(format: "Claude normally keeps at most 6 · about %.1f GB of memory", (i.memoryMB ?? 0) / 1024)
        case tag == "Spinning": return "Busy for \(duration(now.timeIntervalSince(i.started))) with nothing to do"
        case tag == "Tab busy": return "Chrome is busy and you haven't used it in a while"
        case tag == "Open tab": return i.apps.contains("server stopped") ? "Its test website has stopped, so the tab can go" : "Open, but you haven't used Chrome in a while"
        case i.kind == .leftover: return "Claude finished, but this is still running"
        default: return "Running for \(duration(now.timeIntervalSince(i.started)))"
        }
    }

    /// What the button does, so you know nothing important breaks: ("If you stop it", "…") or ("What to do", "…").
    static func advice(_ i: Item) -> (label: String, text: String)? {
        let kept = "Your project files stay as they are."
        switch i.kind {
        case .simulator:
            return ("If you shut it down", "Turns off the pretend \(i.noun.hasPrefix("iPad") ? "iPad" : "iPhone"). Your app and project aren't touched; it can be reopened anytime.")
        case .android:
            return ("If you shut it down", "Turns off the pretend Android phone. Your app and project aren't touched; it can be reopened anytime.")
        case .browserTab:
            return ("If you close it", "Just that tab closes. Nothing else is affected.")
        case .claudePreview:
            return ("What to do", "In Claude, close any preview, artifact or browser panel you're not using. Your chats and files aren't affected.")
        case .spotlight:
            return ("What to do", "In Spotlight settings, open Search Privacy and add the folder below. Spotlight then skips Claude's build files. (You won't find those project files in Spotlight search.)")
        case .cloudSync:
            return ("What to do", "Move Claude's projects out of the synced folder (for example to ~/Developer), so build files stop uploading. Nothing is deleted.")
        case .sleepHold:
            return ("What to do", "In Claude: Settings → Claude Code → turn off “Keep awake on battery”. Claude still keeps the Mac awake while plugged in.")
        case .chatHelper:
            let mem = i.memoryMB.map { $0 >= 1 ? String(format: "Frees about %.0f MB. ", $0) : "" } ?? ""
            return ("If you close it", mem + "The chat isn't deleted and still opens normally; Claude loads a new helper when it needs one."
                    + (i.verdict.tag == "Stuck" ? " Anything that chat was still running also stops." : ""))
        case .helperPileup:
            return ("What to do", "Quit Claude (⌘Q) and reopen it. That closes all the old helpers; your chats are kept.")
        case .chromeExtension:
            return ("What to do", "In Chrome, open ⋮ → More Tools → Task Manager to see which extension it is, then turn it off and on again at chrome://extensions. If it's Claude in Chrome, updating it may help.")
        case .sessionJob:
            return nil
        case .leftover, .appStarted:
            break
        }
        if !i.ports.isEmpty || i.noun == "Test website" {
            return ("If you stop it", "Only the test website stops (its page shows an error until it's started again). \(kept)")
        }
        switch i.noun {
        case "Video export": return ("If you stop it", "Stops the export; the half-made video stays unfinished. Nothing else is affected.")
        case "App build": return ("If you stop it", "Stops the build; the app just isn't updated until it's built again. \(kept)")
        case "Keep-awake command": return ("If you stop it", "Your Mac can sleep normally again. Nothing else changes.")
        default:
            let what = i.noun.hasPrefix("Program") ? "this program" : "this \(i.noun.lowercased())"
            return ("If you stop it", "Stops \(what) and anything it started. Unfinished work it was doing is lost. \(kept)")
        }
    }

    private static func scriptName(_ p: ProcRecord) -> String? {
        let rest = Array(p.args.dropFirst())
        if let i = rest.firstIndex(of: "-m"), i + 1 < rest.count { return rest[i + 1] }
        if rest.contains("-c") || rest.contains("-e") { return "one-liner" }
        return rest.first { !$0.hasPrefix("-") }.map { ($0 as NSString).lastPathComponent }
    }

    static func duration(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        if m < 1 { return "under a minute" }
        if m < 60 { return "\(m) min" }
        let h = m / 60
        if h < 48 { return "\(h) h" }
        return "\(h / 24) days"
    }
}
