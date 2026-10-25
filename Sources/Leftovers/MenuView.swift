import SwiftUI

let menuWidth: CGFloat = 470

/// The dropdown under the menu-bar icon.
final class UIState: ObservableObject {
    static let shared = UIState()
    @Published var showSettings = false
    var expandID: String?   // pictures only: open this row's Details

    /// Tells the dropdown to re-measure itself (row Details opening or closing changes its height).
    func contentChanged() {
        DispatchQueue.main.async { self.objectWillChange.send() }
    }
    var tallForPicture = false   // README picture only: no scrolling
}

struct MenuView: View {
    @EnvironmentObject var m: Monitor
    @ObservedObject var ui = UIState.shared

    /// Only rows you can do something about: leftovers, simulators, servers, and a sleep hold that is a problem.
    private var shown: [Item] {
        m.items.filter { i in
            switch i.kind {
            case .leftover, .appStarted, .sessionJob, .simulator, .android: true
            case .claudePreview, .claudePlayback, .spotlight, .cloudSync, .helperPileup, .chatHelper:
                i.verdict.level >= .warn
            }
        }
    }

    private var sorted: [Item] {
        shown.sorted { ($0.verdict.level, $0.watts) > ($1.verdict.level, $1.watts) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 12)
            if ui.showSettings {
                SettingsView()
            } else {
                list
            }
            Divider().padding(.horizontal, 12)
            footer
        }
        .frame(width: menuWidth)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                StatusBanner(rows: shown)
                let problems = sorted.filter { $0.verdict.level >= .warn }
                let inactive = sorted.filter { $0.verdict.level == .info }
                let inUse = sorted.filter { $0.verdict.level == .none }
                ForEach(problems) { ItemRow(item: $0, expanded: $0.id == ui.expandID) }
                if !inactive.isEmpty {
                    SectionTitle(text: "Running · inactive", note: "Not doing anything; stop them before they waste battery")
                    ForEach(inactive) { ItemRow(item: $0) }
                }
                if !inUse.isEmpty {
                    SectionTitle(text: "Running · in use", note: "Being used right now")
                    ForEach(inUse) { ItemRow(item: $0) }
                }
            }
            .padding(12)
        }
        .frame(maxHeight: ui.tallForPicture ? 1400 : min(640, (NSScreen.main?.visibleFrame.height ?? 900) - 160))
    }

    private var header: some View {
        Text(ui.showSettings ? "Leftovers Settings" : "Leftovers")
            .font(.system(size: 17, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var footer: some View {
        footerButtons
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private var footerButtons: some View {
        HStack(spacing: 12) {
            if let t = m.scannedAt {
                TimelineView(.periodic(from: .now, by: 15)) { ctx in
                    let ago = ctx.date.timeIntervalSince(t)
                    Text(ago < 60 ? "Checked just now" : "Checked \(Describe.duration(ago)) ago")
                }
            }
            Spacer()
            if ui.showSettings {
                Button("Check for Updates…") { Updates.check() }
                Button("Done") { ui.showSettings = false }
                Button("Quit") { NSApp.terminate(nil) }
            } else {
                Button("Check now") { m.scan() }
                Button("Quit") { NSApp.terminate(nil) }
                Button { ui.showSettings = true } label: { Image(systemName: "gearshape") }.help("Settings")
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
    }
}

/// The answer to "did Claude leave anything running?", always at the top. One state at a time: problems
/// (orange/red), else idle things (orange), else all clear (green).
struct StatusBanner: View {
    let rows: [Item]

    private var problems: [Item] { rows.filter { $0.verdict.level >= .warn } }
    private var idle: [Item] { rows.filter { $0.verdict.level == .info } }

    var body: some View {
        let (icon, color, title, subtitle) = content
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.15)))
    }

    private func count(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }

    private var content: (String, Color, String, String) {
        if !problems.isEmpty {
            let red = problems.contains { $0.verdict.level == .alarm }
            return ("exclamationmark.circle.fill", red ? .red : .orange,
                    count(problems.count, "thing needs a look", "things need a look"),
                    "Claude left something running that's wasting battery.")
        }
        if !idle.isEmpty {
            return ("pause.circle.fill", .orange,
                    count(idle.count, "thing sitting idle", "things sitting idle"),
                    "Claude left \(idle.count == 1 ? "this" : "these") running. Stop \(idle.count == 1 ? "it" : "them") when you're done.")
        }
        return ("checkmark.circle.fill", .green, "All clear",
                rows.isEmpty ? "Claude hasn't left anything running." : "Everything Claude started is in use.")
    }
}

struct ItemRow: View {
    let item: Item
    @EnvironmentObject var m: Monitor
    @State private var expanded: Bool
    @State private var stopping = false

    init(item: Item, expanded: Bool = false) {
        self.item = item
        _expanded = State(initialValue: expanded)
    }

    /// The icon says what kind of thing it is (loop, script, build, website, phone…); its color says how serious.
    var icon: String { Describe.icon(item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .frame(width: 22)
                    .foregroundStyle(item.verdict.level >= .info ? levelColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Describe.summary(item))
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(item.status)
                        .font(.system(size: 13))
                        .foregroundStyle(item.verdict.level >= .info ? levelColor : Color.secondary)
                }
                Spacer(minLength: 4)
                if let cost = costText {
                    Text(cost)
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(costColor.opacity(0.18)))
                        .foregroundStyle(costColor)
                        .help("Share of your battery this uses per hour")
                }
            }
            if let advice = Describe.advice(item) {
                (Text(advice.label + ": ").fontWeight(.semibold) + Text(advice.text))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 30)
            }
            HStack(spacing: 14) {
                ForEach(actions, id: \.0) { label, action in
                    Button(label, action: action)
                }
                Spacer()
                Button {
                    expanded.toggle()
                    UIState.shared.contentChanged()
                } label: {
                    HStack(spacing: 3) {
                        Text("Details")
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 14, weight: .medium))
            .padding(.leading, 30)
            .disabled(stopping)
            if expanded { details.padding(.leading, 30) }
        }
        .opacity(item.verdict.tag == "Ignored" ? 0.55 : 1)
        .padding(.vertical, 10).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    /// The technical facts, for when you want to know exactly what it is.
    private var details: some View {
        let now = Date()
        var rows: [(String, String)] = []
        switch item.kind {
        case .simulator:
            rows.append(("Device", item.title))
            if !item.apps.isEmpty { rows.append(("App", item.apps.joined(separator: ", "))) }
            rows.append(("Booted", Describe.duration(now.timeIntervalSince(item.started)) + " ago"))
        case .android:
            rows.append(("Device", item.title))
            rows.append(("Running for", Describe.duration(now.timeIntervalSince(item.started))))
        case .spotlight, .cloudSync:
            rows.append(("Busy", String(format: "%.0f%% CPU", item.cpuPercent)))
            for (n, f) in item.apps.enumerated() { rows.append((n == 0 ? "Build folders" : " ", f)) }
        case .claudePreview, .claudePlayback:
            rows.append(("Busy", String(format: "%.0f%% CPU", item.cpuPercent)))
        case .chatHelper:
            rows.append(("Chat", item.title))
            if let mb = item.memoryMB { rows.append(("Memory", String(format: "%.0f MB", mb))) }
            rows.append(("Running for", Describe.duration(now.timeIntervalSince(item.started))))
        case .helperPileup:
            if let mb = item.memoryMB { rows.append(("Memory", String(format: "%.1f GB in total", mb / 1024))) }
            for (n, chat) in item.apps.enumerated() { rows.append((n == 0 ? "Chats loaded" : " ", chat)) }
        default:
            rows.append(("Program", item.title))
            if let s = item.starter { rows.append(("Started by", s)) }
            if let s = item.session { rows.append(("Claude chat", "“\(s)”" + (item.sessionGuessed ? " (probably)" : ""))) }
            if let f = item.folder { rows.append(("Folder", (f as NSString).abbreviatingWithTildeInPath)) }
            rows.append(("Running for", Describe.duration(now.timeIntervalSince(item.started))))
            if let out = item.lastOutput { rows.append(("Last saved output", Describe.duration(now.timeIntervalSince(out)) + " ago")) }
            if !item.ports.isEmpty {
                rows.append(("Address", item.ports.map { "localhost:\($0)" }.joined(separator: ", ")))
                rows.append(("Visitors now", item.connections == 0 ? "none" : "\(item.connections)"))
            }
        }
        for note in item.notes {
            let parts = note.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { rows.append((parts[0], parts[1])) }
        }
        if let b = item.batteryPerHour {
            rows.append(("Battery", String(format: "~%.1f%% an hour (%.0f%% CPU)", b, item.cpuPercent)))
        }
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                let (k, v) = row
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(k).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                    Text(v).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            if [.leftover, .appStarted, .sessionJob].contains(item.kind) {
                Text(item.command)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .padding(.top, 2)
            }
        }
        .font(.system(size: 13))
    }

    private var levelColor: Color {
        switch item.verdict.level {
        case .alarm: .red
        case .warn, .info: .orange
        default: .secondary
        }
    }

    private var actions: [(String, () -> Void)] {
        if stopping {
            return [([.simulator, .android].contains(item.kind) ? "Shutting down…" : "Stopping…", {})]
        }
        var a: [(String, () -> Void)] = []
        let stop = { stopping = true; m.stop(item) }
        if !item.ports.isEmpty { a.append(("Open", { m.openInBrowser(item) })) }
        switch item.kind {
        case .leftover, .appStarted, .simulator:
            if item.kind != .appStarted || item.verdict.level >= .info {
                a.append((item.kind == .simulator ? "Shut down" : "Stop", stop))
            }
            if m.kept[item.keepKey] == nil, item.verdict.level >= .info { a.append(("Ignore", { m.keep(item) })) }
        case .android:
            a.append(("Shut down", stop))
            if m.kept[item.keepKey] == nil, item.verdict.level >= .info { a.append(("Ignore", { m.keep(item) })) }
        case .claudePreview, .claudePlayback:
            a.append(("Open Claude", { m.openClaude() }))
        case .spotlight:
            a.append(("Open Spotlight settings", { m.openSpotlightSettings() }))
            a.append(("Don't warn again", { m.switchOff(item) }))
        case .chatHelper:
            if !item.busy { a.append(("Close", stop)) }
        case .helperPileup:
            break
        case .cloudSync:
            if let f = item.apps.first { a.append(("Show folder", { m.reveal(f) })) }
            a.append(("Don't warn again", { m.switchOff(item) }))
        case .sessionJob:
            if item.verdict.tag == "Looks stuck" {
                a.append(("Stop", stop))
                if m.kept[item.keepKey] == nil { a.append(("Ignore", { m.keep(item) })) }
            }
        }
        return a
    }

    private var costText: String? {
        guard let b = item.batteryPerHour else { return nil }
        if b < 0.5 { return "<1%/h" }
        return String(format: "%.0f%%/h", b)
    }

    private var costColor: Color {
        let b = item.batteryPerHour ?? 0
        return b >= 10 ? .red : b >= 3 ? .orange : .secondary
    }
}


struct SectionTitle: View {
    let text: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(text.uppercased()).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Text(note).font(.system(size: 12)).foregroundStyle(.tertiary)
        }
        .padding(.top, 6).padding(.horizontal, 4)
    }
}
