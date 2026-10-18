import SwiftUI

let menuWidth: CGFloat = 400

/// The dropdown under the menu-bar icon.
struct MenuView: View {
    @EnvironmentObject var m: Monitor

    private var sections: [(ItemKind, [Item])] {
        let order: [ItemKind] = [.leftover, .sleepHold, .simulator, .sessionJob, .appStarted, .claudeApp]
        return order.compactMap { kind in
            let list = m.items.filter { $0.kind == kind }.sorted {
                ($0.verdict.level, $0.watts) > ($1.verdict.level, $1.watts)
            }
            return list.isEmpty ? nil : (kind, list)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !sections.contains(where: { $0.0 != .claudeApp }) {
                        Label("Nothing left running", systemImage: "leaf")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 14)
                    }
                    ForEach(sections, id: \.0) { kind, list in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(kind.heading.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                            ForEach(list) { ItemRow(item: $0) }
                        }
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 460)
            Divider().padding(.horizontal, 12)
            footer
        }
        .frame(width: menuWidth)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Leftovers").font(.headline)
            Spacer()
            Text(batteryLine).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var batteryLine: String {
        let b = m.battery
        var s = b.onBattery ? "On battery" : "Plugged in"
        if let p = b.percent { s += " · \(p)%" }
        if b.lowPowerMode { s += " · Low Power" }
        return s
    }

    private var ownCost: String {
        let pct = m.battery.capacityWh > 0 ? m.ownWatts / m.battery.capacityWh * 100 : 0
        return pct < 0.1 ? "<0.1%/h" : String(format: "%.1f%%/h", pct)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let t = m.scannedAt {
                TimelineView(.periodic(from: .now, by: 15)) { ctx in
                    let ago = ctx.date.timeIntervalSince(t)
                    Text(ago < 60 ? "Checked just now" : "Checked \(Describe.duration(ago)) ago")
                }
            }
            Text("· Leftovers itself: " + ownCost).help(String(format: "%.3f W", m.ownWatts))
            Spacer()
            Button("Check now") { m.scan() }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
}

struct ItemRow: View {
    let item: Item
    @EnvironmentObject var m: Monitor
    @State private var expanded = false
    @State private var stopping = false

    var icon: String {
        switch item.kind {
        case .leftover: "exclamationmark.triangle"
        case .sessionJob: "gearshape.2"
        case .appStarted: "server.rack"
        case .simulator: "iphone"
        case .sleepHold: "moon.zzz"
        case .claudeApp: "sparkle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 18)
                    .foregroundStyle(item.verdict.level >= .warn ? levelColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        if !item.verdict.tag.isEmpty {
                            Text(item.verdict.tag)
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(levelColor.opacity(0.18)))
                                .foregroundStyle(levelColor)
                                .fixedSize()
                        }
                    }
                    Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if let extra = extraLine {
                        Text(extra).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let cost = costText {
                    Text(cost)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(costColor.opacity(0.18)))
                        .foregroundStyle(costColor)
                        .help(String(format: "%.1f W · %.0f%% CPU", item.watts, item.cpuPercent))
                }
            }
            if !actions.isEmpty {
                HStack(spacing: 14) {
                    ForEach(actions, id: \.0) { label, action in
                        Button(label, action: action)
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium))
                .padding(.leading, 26)
                .disabled(stopping)
            }
            if expanded {
                Text(item.command)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .padding(.leading, 26)
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
    }

    private var levelColor: Color {
        switch item.verdict.level {
        case .alarm: .red
        case .warn: .orange
        default: .secondary
        }
    }

    private var actions: [(String, () -> Void)] {
        if stopping { return [(item.kind == .simulator ? "Shutting down…" : "Stopping…", {})] }
        var a: [(String, () -> Void)] = []
        let stop = { stopping = true; m.stop(item) }
        switch item.kind {
        case .leftover, .appStarted, .simulator:
            if item.kind != .appStarted || item.verdict.level >= .info {
                a.append((item.kind == .simulator ? "Shut down" : "Stop", stop))
            }
            if m.kept[item.keepKey] != nil {
                a.append(("Stop keeping", { m.unkeep(item.keepKey) }))
            } else if item.verdict.level >= .info {
                a.append(("Keep", { m.keep(item) }))
            }
            if item.verdict.level >= .warn { a.append(("Snooze 1 h", { m.snooze(item) })) }
        case .sleepHold:
            if item.verdict.level >= .info { a.append(("Open Claude", { m.openClaude() })) }
        default: break
        }
        return a
    }

    private var extraLine: String? {
        var parts: [String] = []
        if let p = item.project, item.kind != .simulator { parts.append(p) }
        if let out = item.lastOutput {
            parts.append("last wrote output \(Describe.duration(Date().timeIntervalSince(out))) ago")
        }
        if !item.ports.isEmpty {
            parts.append(item.connections == 0 ? "no one connected" : "\(item.connections) connected")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var costText: String? {
        guard let b = item.batteryPerHour, item.kind != .sleepHold else { return nil }
        if b < 0.5 { return "<1%/h" }
        return String(format: "%.0f%%/h", b)
    }

    private var costColor: Color {
        let b = item.batteryPerHour ?? 0
        return b >= 10 ? .red : b >= 3 ? .orange : .secondary
    }
}
