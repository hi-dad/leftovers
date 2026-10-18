import Foundation

/// Facts for the checks beyond Claude's own processes: Spotlight, cloud sync and Chrome tabs.
enum Extras {
    /// CPU % of every process (including system ones Leftovers can't measure directly), via ps.
    static func systemCPU() -> [(pid: pid_t, name: String, cpu: Double)] {
        guard let out = run("/bin/ps", ["-Ao", "pid=,pcpu=,comm="]) else { return [] }
        return out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = pid_t(parts[0]), let cpu = Double(parts[1]) else { return nil }
            return (pid, (String(parts[2]) as NSString).lastPathComponent, cpu)
        }
    }

    static let spotlightProcesses: Set<String> = ["mds", "mds_stores", "mdworker", "mdworker_shared", "mdbulkimport"]
    static let syncProcesses: Set<String> = [
        "bird", "fileproviderd", "cloudd", "OneDrive", "OneDrive Sync Service", "OneDrive File Provider",
        "Dropbox", "Google Drive", "FinderSyncExtension",
    ]

    static let buildFolderNames = ["node_modules", ".build", "build", "DerivedData", "Pods", ".venv", "venv", "dist", ".next", "target"]

    /// Build folders inside Claude's project folders that changed recently (what Spotlight or a sync app
    /// would be busy with). Reads folder dates only, never file contents.
    static func recentBuildFolders(in roots: [String], within: TimeInterval, now: Date) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        for root in roots {
            let projects = [root] + ((try? fm.contentsOfDirectory(atPath: root)) ?? []).map { root + "/" + $0 }
            for project in projects {
                for name in buildFolderNames {
                    let path = project + "/" + name
                    guard let attrs = try? fm.attributesOfItem(atPath: path),
                          attrs[.type] as? FileAttributeType == .typeDirectory,
                          let mod = attrs[.modificationDate] as? Date, now.timeIntervalSince(mod) < within else { continue }
                    out.append((path as NSString).abbreviatingWithTildeInPath)
                }
            }
        }
        return out
    }

    /// Claude folders that a sync service (iCloud, OneDrive, Dropbox, Google Drive) uploads.
    static func syncedFolders(_ roots: [String]) -> [String] {
        let home = NSHomeDirectory()
        func finderPref(_ key: String) -> Bool {
            (CFPreferencesCopyAppValue(key as CFString, "com.apple.finder" as CFString) as? Bool) ?? false
        }
        let desktopSynced = finderPref("FXICloudDriveDesktop"), documentsSynced = finderPref("FXICloudDriveDocuments")
        return roots.filter { f in
            let real = (f as NSString).resolvingSymlinksInPath
            return [home + "/Library/Mobile Documents/", home + "/Library/CloudStorage/", home + "/Dropbox/"]
                .contains { real.hasPrefix($0) }
                || (desktopSynced && real.hasPrefix(home + "/Desktop/"))
                || (documentsSynced && real.hasPrefix(home + "/Documents/"))
        }
    }

    struct Tab { var url: String; var title: String }

    /// Chrome tabs showing a local test page or a file from a Claude folder. Only called while Chrome is
    /// running (asking a closed Chrome would open it). The first call shows macOS's "control Chrome" prompt.
    static func chromeTabs(claudeFolders: [String]) -> [Tab] {
        let script = """
        set out to ""
        tell application "Google Chrome"
            repeat with w in windows
                repeat with t in tabs of w
                    set out to out & (URL of t) & tab & (title of t) & linefeed
                end repeat
            end repeat
        end tell
        return out
        """
        guard let out = run("/usr/bin/osascript", ["-e", script]) else { return [] }
        return out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard let url = parts.first, isClaudePage(url, folders: claudeFolders) else { return nil }
            return Tab(url: url, title: parts.count > 1 ? parts[1] : url)
        }
    }

    static func isClaudePage(_ url: String, folders: [String]) -> Bool {
        guard let u = URL(string: url) else { return false }
        if u.scheme == "file" { return folders.contains { u.path.hasPrefix($0 + "/") } || u.path.contains("/tmp/claude-") }
        return ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"].contains(u.host ?? "")
    }

    static func closeChromeTabs(url: String) {
        let quoted = url.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        _ = run("/usr/bin/osascript", ["-e", """
        tell application "Google Chrome"
            repeat with w in windows
                close (every tab of w whose URL is "\(quoted)")
            end repeat
        end tell
        """])
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> String? {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
