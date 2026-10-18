import AppKit
import IOKit.ps
import UserNotifications

/// Posts one notification per problem (again only if it gets worse), with Stop/Keep/Snooze buttons,
/// plus a single heads-up when you unplug while things are still running.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    let m = Monitor.shared
    var onReview: (() -> Void)?
    private var notified: [String: Level] = [:]   // item id → highest level already announced
    private var powerSource: CFRunLoopSource?

    func start() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let stop = UNNotificationAction(identifier: "stop", title: "Stop it", options: [.destructive])
        let shut = UNNotificationAction(identifier: "stop", title: "Shut down", options: [.destructive])
        let keep = UNNotificationAction(identifier: "keep", title: "Keep running")
        let snooze = UNNotificationAction(identifier: "snooze", title: "Remind me in an hour")
        let claude = UNNotificationAction(identifier: "claude", title: "Open Claude", options: [.foreground])
        let review = UNNotificationAction(identifier: "review", title: "Review", options: [.foreground])
        c.setNotificationCategories([
            UNNotificationCategory(identifier: "leftover", actions: [stop, keep, snooze], intentIdentifiers: []),
            UNNotificationCategory(identifier: "simulator", actions: [shut, keep, snooze], intentIdentifiers: []),
            UNNotificationCategory(identifier: "sleep", actions: [claude, snooze], intentIdentifiers: []),
            UNNotificationCategory(identifier: "review", actions: [review], intentIdentifiers: []),
        ])

        m.onScanned = { [weak self] wasOnBattery in self?.afterScan(wasOnBattery: wasOnBattery) }

        // Rescan the moment the power source changes, so the unplug heads-up is immediate.
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ _ in Monitor.shared.scan() }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            powerSource = src
        }
    }

    private func afterScan(wasOnBattery: Bool) {
        guard UserDefaults.standard.object(forKey: "notify") as? Bool ?? true else { return }
        let quiet = m.battery.lowPowerMode
        let current = Set(m.items.map(\.id))
        notified = notified.filter { current.contains($0.key) }

        for i in m.items where i.verdict.level >= .warn {
            guard (notified[i.id] ?? .none) < i.verdict.level else { continue }
            notified[i.id] = i.verdict.level
            let title: String
            switch i.kind {
            case .leftover: title = i.verdict.level == .alarm ? "\(i.title) looks stuck" : "A leftover from Claude is still running"
            case .simulator: title = "\(i.title) is running unused"
            case .sleepHold: title = "Claude is keeping your Mac awake"
            default: title = i.title
            }
            let category = i.kind == .simulator ? "simulator" : i.kind == .sleepHold ? "sleep" : "leftover"
            post(id: i.id, title: title, body: i.verdict.message, category: category, quiet: quiet)
        }

        // Just unplugged: one summary of what is still running.
        if !wasOnBattery && m.battery.onBattery {
            let sims = m.items.filter { $0.kind == .simulator }.count
            let left = m.items.filter { $0.kind == .leftover && !m.kept.keys.contains($0.keepKey) }.count
            let servers = m.items.filter { $0.kind == .appStarted && !$0.ports.isEmpty }.count
            var parts: [String] = []
            if left > 0 { parts.append(left == 1 ? "1 leftover" : "\(left) leftovers") }
            if sims > 0 { parts.append(sims == 1 ? "1 simulator" : "\(sims) simulators") }
            if servers > 0 { parts.append(servers == 1 ? "1 dev server" : "\(servers) dev servers") }
            if !parts.isEmpty {
                let list = ListFormatter.localizedString(byJoining: parts)
                post(id: "unplugged", title: "You're on battery",
                     body: "Still running from Claude: \(list).", category: "review", quiet: quiet)
            }
        }
    }

    private func post(id: String, title: String, body: String, category: String, quiet: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = ["item": id]
        content.sound = quiet ? nil : .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let id = r.notification.request.content.userInfo["item"] as? String
        DispatchQueue.main.async { [self] in
            let item = m.items.first { $0.id == id }
            switch r.actionIdentifier {
            case "stop": if let item { m.stop(item) }
            case "keep": if let item { m.keep(item) }
            case "snooze": if let item { m.snooze(item) }
            case "claude": m.openClaude()
            default: onReview?()   // "Review" or a click on the notification itself
            }
            done()
        }
    }
}
