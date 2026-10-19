import Foundation

/// Facts for the checks beyond Claude's own processes: Spotlight and cloud sync.
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
