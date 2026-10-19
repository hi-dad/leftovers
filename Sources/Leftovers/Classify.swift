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
    /// Folders Claude chats have worked in (read from Claude's own records, never set by hand). Only a backup
    /// for recognising a leftover Leftovers never saw being started.
    var watchedFolders: [String]
    /// Claude Code's settings folder (~/.claude unless Claude was told to keep it elsewhere).
    var configDir: String
    /// Processes Leftovers saw a Claude chat or the Claude app start ("pid-starttime"). After the chat closes
    /// they're still known to be Claude's, whatever folder they run in.
    var remembered: Set<String>

    init(home: String = NSHomeDirectory(), watchedFolders: [String] = [], configDir: String? = nil,
         remembered: Set<String> = []) {
        self.home = home
        self.watchedFolders = watchedFolders
        self.configDir = configDir ?? home + "/.claude"
        self.remembered = remembered
    }

    static func key(_ p: ProcRecord) -> String { "\(p.pid)-\(Int(p.start.timeIntervalSince1970))" }

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
            s.contains("/tmp/claude-") || s.contains(configDir + "/")
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
        where p.ppid == 1 && !claimed.contains(p.pid) && !isAppOrSystem(p)
            && (remembered.contains(Self.key(p)) || isClaudeish(p)) {
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
        case .android:
            return "Android emulator running (\(i.title))"
        case .claudePlayback:
            switch i.noun {
            case "Video": return "Video playing in Claude"
            case "Simulator screen": return "Simulator screen streaming in Claude"
            default: return "Animation or artifact playing in Claude"
            }
        case .claudePreview:
            return "Claude app busy while no chat is working"
        case .spotlight:
            return "Spotlight re-indexing files on every Claude build"
        case .cloudSync:
            return "Cloud sync re-uploading files on every Claude build"
        case .chatHelper:
            return i.verdict.tag == "Stuck" ? "Claude chat stuck in a loop: “\(i.title)”" : "“\(i.title)”"
        case .helperPileup:
            return "Too many Claude chats loaded (\(i.apps.count))"
        case .appStarted, .sessionJob:
            if i.verdict.tag == "Looks stuck" { return "\(i.noun) stuck\(place)" }
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

    /// Category icon (SF Symbols): anything stuck in a loop shares one icon; otherwise it shows the kind of thing.
    static func icon(_ i: Item) -> String {
        if ["Looks stuck", "Stuck"].contains(i.verdict.tag) { return "arrow.triangle.2.circlepath" }
        switch i.kind {
        case .simulator: return "iphone"
        case .android: return "smartphone"
        case .chatHelper, .helperPileup: return "bubble.left.and.bubble.right"
        case .claudePlayback: return "play.rectangle"
        case .claudePreview: return "macwindow"
        case .spotlight: return "magnifyingglass"
        case .cloudSync: return "icloud.and.arrow.up"
        case .leftover, .appStarted, .sessionJob: break
        }
        if !i.ports.isEmpty || i.noun == "Test website" { return "globe" }
        switch i.noun {
        case "Video export": return "film"
        case "App build": return "hammer"
        case "Keep-awake command": return "moon.zzz"
        default: return "terminal"
        }
    }

    /// One short line under each row: whether stopping it is safe (or what it breaks), or the fix when there's
    /// nothing to stop. ("Safe to stop", "its Claude chat already finished")
    static func advice(_ i: Item) -> (label: String, text: String)? {
        let stuck = i.verdict.tag == "Looks stuck"
        switch i.kind {
        case .simulator, .android:
            return ("Safe to shut down", "your app and project aren't touched")
        case .chatHelper:
            return ("Safe to close", "the chat stays and reopens normally")
        case .helperPileup:
            return ("Fix", "quit Claude (⌘Q) and reopen it; your chats are kept")
        case .claudePlayback:
            if i.noun == "Simulator screen" {
                return ("Fix", "close the simulator panel in Claude; the simulator itself keeps running")
            }
            return ("Fix", "close the preview, artifact or browser tab that's playing; your chats aren't affected")
        case .claudePreview:
            return ("Fix", "quit Claude (⌘Q) and reopen it; your chats are kept")
        case .spotlight:
            // The projects folder is two levels above a build folder (~/Desktop/claude/<project>/node_modules).
            let root = i.apps.first.map { (($0 as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent } ?? "your Claude projects folder"
            return ("Fix", "add \(root) to Spotlight's Search Privacy list")
        case .cloudSync:
            return ("Fix", "move Claude's projects out of the synced folder, e.g. to ~/Developer")
        case .sessionJob:
            return stuck ? ("Safe to stop", "it isn't making progress") : nil
        case .leftover, .appStarted:
            break
        }
        if !i.ports.isEmpty || i.noun == "Test website" {
            return ("Stopping", "closes the test website until it's restarted")
        }
        switch i.noun {
        case "App build": return ("Stopping", "cancels this build; Claude can run it again")
        case "Keep-awake command": return ("Safe to stop", "your Mac can sleep again")
        case "Video export" where !stuck: return ("Stopping", "cancels the export before it finishes")
        default:
            return ("Safe to stop", stuck ? "it isn't making progress" : "its Claude chat already finished")
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
