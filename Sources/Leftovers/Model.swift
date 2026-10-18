import Foundation

/// One process, as read from the process table.
struct ProcRecord: Equatable {
    var pid: pid_t
    var ppid: pid_t
    var name: String
    var path: String
    var args: [String]
    var cwd: String
    var start: Date

    var commandLine: String { args.isEmpty ? name : args.joined(separator: " ") }
}

struct WrittenFile: Codable, Equatable {
    var path: String
    var size: Int64
    var modified: Date
}

/// A Claude session, read from the Claude app's own session files.
struct SessionInfo: Codable, Equatable {
    var cliSessionId: String
    var title: String
    var cwd: String
    var createdAt: Date
    var lastActivityAt: Date
    var archived: Bool
}

enum ItemKind: String, Codable, CaseIterable {
    case leftover      // its Claude session is gone, but it is still running
    case sessionJob    // started by a Claude session that is running right now
    case appStarted    // started by the Claude app itself (preview servers and the like)
    case simulator     // a booted iPhone/iPad simulator
    case sleepHold     // something keeping the Mac from sleeping
    case claudePreview // the Claude app's windows busy drawing (an animated preview or artifact)
    case spotlight     // Spotlight busy indexing Claude's build folders
    case cloudSync     // iCloud/OneDrive/Dropbox busy uploading Claude's build folders
    case android       // an Android emulator
    case browserTab    // a Chrome tab showing one of Claude's test pages
}

/// One row in the menu: a process family, a simulator, or a sleep hold.
struct Item: Identifiable, Codable, Equatable {
    var id: String
    var kind: ItemKind
    var title: String
    var detail: String
    var command: String
    var session: String?          // title of the Claude session that started it
    var sessionGuessed = false    // matched by folder + time rather than an exact id
    var project: String?
    var folder: String?           // working folder of the root process
    var pids: [pid_t]
    var started: Date
    var cpuPercent: Double = 0
    var watts: Double = 0
    var batteryPerHour: Double?   // % of a full battery used per hour
    var ports: [UInt16] = []
    var connections = 0
    var lastOutput: Date?         // newest change to a file it is writing
    var averageCpu: Double = 0    // CPU % averaged over each process's whole life
    var startTimes: [Double] = [] // start time of each pid, so Stop never hits a reused pid
    var keepKey = ""              // what "Keep" remembers (project + command, or device + boot)
    var verdict = Verdict(level: .none, tag: "")
    var noun = ""                 // plain name of what it is ("Python script", "Video export")
    var starter: String?          // the script that started it, when that's a different program
    var apps: [String] = []       // apps open in a simulator
}

struct BatteryState: Codable, Equatable {
    var onBattery: Bool
    var percent: Int?
    var capacityWh: Double
    var lowPowerMode: Bool
}

struct Status: Codable {
    var scannedAt: Date
    var battery: BatteryState
    var items: [Item]
}
