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
    case claudeApp     // the Claude app's own processes, for comparison

    var heading: String {
        switch self {
        case .leftover: "Left behind"
        case .sessionJob: "Running in a Claude session"
        case .appStarted: "Started by the Claude app"
        case .simulator: "Simulators"
        case .sleepHold: "Keeping your Mac awake"
        case .claudeApp: "The Claude app itself"
        }
    }
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
    var pids: [pid_t]
    var started: Date
    var cpuPercent: Double = 0
    var watts: Double = 0
    var batteryPerHour: Double?   // % of a full battery used per hour
    var ports: [UInt16] = []
    var connections = 0
    var lastOutput: Date?         // newest change to a file it is writing
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
