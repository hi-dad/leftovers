import AppKit
import ServiceManagement
import SwiftUI

/// Settings, shown inside the dropdown (gear button).
struct SettingsView: View {
    @EnvironmentObject var m: Monitor
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var notify = UserDefaults.standard.object(forKey: "notify") as? Bool ?? true
    @State private var folders = Classifier.savedFolders()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Open at login", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { _, on in
                    do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                    catch { openAtLogin = SMAppService.mainApp.status == .enabled }
                }
            Toggle("Notify me about leftovers", isOn: $notify)
                .onChange(of: notify) { _, on in UserDefaults.standard.set(on, forKey: "notify") }

            section("Project folders",
                    note: "Anything still running from these folders after its Claude chat ends counts as a leftover. Also watched automatically: Claude's scratch folders and every folder a Claude chat has worked in\(autoCount).") {
                ForEach(folders, id: \.self) { f in
                    row((f as NSString).abbreviatingWithTildeInPath, button: "Remove") {
                        folders.removeAll { $0 == f }; save()
                    }
                }
                Button("Add folder…", action: addFolder).buttonStyle(.borderless).font(.system(size: 13, weight: .medium))
            }

            section("Kept running", note: "Things you chose to keep. Leftovers lists them but won't warn about them.") {
                if m.kept.isEmpty {
                    Text("Nothing yet").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                ForEach(m.kept.sorted { $0.value < $1.value }, id: \.key) { key, label in
                    row(label, button: "Forget") { m.unkeep(key) }
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.regular)
        .font(.system(size: 14))
        .padding(14)
    }

    private func section<C: View>(_ title: String, note: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            content()
            Text(note).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(text).font(.system(size: 14)).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button(button, action: action).buttonStyle(.borderless).font(.system(size: 13, weight: .medium))
        }
    }

    private var autoCount: String {
        let n = SessionIndex.load().workFolders.count
        return n > 0 ? " (\(n) right now)" : ""
    }

    private func save() {
        UserDefaults.standard.set(folders, forKey: "watchedFolders")
        m.scan()
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Watch Folder"
        panel.level = .popUpMenu + 1
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url, !folders.contains(url.path) {
            folders.append(url.path); save()
        }
    }
}
