import AppKit
import Foundation
import SwiftUI
import UserNotifications

/// Tracks observed exhaustion, never infers restored quota from the clock alone.
struct ResetPingTracker: Codable {
    struct Watch: Codable, Identifiable {
        var id: String
        var provider: String
        var label: String
        var reset: Date
        var exhaustedAt: Date
        var token: String { "\(id):\(reset.timeIntervalSince1970)" }
    }
    struct Ping: Codable, Identifiable {
        var id: String
        var provider: String
        var label: String
        var date: Date
        var used: Double
    }
    var watches: [String: Watch] = [:]
    var history: [Ping] = []
    var completed: [String] = []

    mutating func observe(_ snapshots: [UsageSnapshot], enabled: Set<String>, snoozed: Bool, now: Date) -> [Ping] {
        watches = watches.filter { enabled.contains($0.value.provider) && now.timeIntervalSince($0.value.reset) < 24 * 3600 }
        var pings: [Ping] = []
        for snapshot in snapshots where enabled.contains(snapshot.provider) {
            let windows: [(String, String, UsageSnapshot.WindowMetric?)] = [
                ("session", "short window", snapshot.currentSession),
                ("week", "weekly window", snapshot.week),
                ("fable", "Fable weekly window", snapshot.weekFable)
            ]
            for (role, label, metric) in windows {
                guard let metric, !metric.isExpired, !metric.isUnknown,
                      let used = metric.usedPct, used.isFinite, used >= 0,
                      let observed = UsageInsights.parseDate(metric.eventAt ?? metric.capturedAt ?? snapshot.eventAt ?? snapshot.capturedAt ?? snapshot.updatedAt),
                      observed <= now, now.timeIntervalSince(observed) <= 15 * 60,
                      let reset = UsageInsights.resetDate(for: metric, now: now), reset > now
                else { continue }
                let id = "\(snapshot.provider).\(role)"
                if let watch = watches[id], now >= watch.reset, observed >= watch.reset,
                   reset > watch.reset, used < 100, !snoozed {
                    let ping = Ping(id: watch.token, provider: snapshot.provider, label: label, date: now, used: used)
                    pings.append(ping)
                    history.insert(ping, at: 0)
                    completed.append(watch.token)
                    watches.removeValue(forKey: id)
                }
                if used >= 100 {
                    let watch = Watch(id: id, provider: snapshot.provider, label: label, reset: reset,
                                      exhaustedAt: watches[id]?.exhaustedAt ?? now)
                    if !completed.contains(watch.token) { watches[id] = watch }
                }
            }
        }
        history = Array(history.prefix(20))
        completed = Array(completed.suffix(100))
        return pings
    }
}

@MainActor
final class ResetPingController: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let providers = ["claude", "codex", "gemini", "grok"]
    @Published private(set) var enabled: Set<String>
    @Published private(set) var tracker: ResetPingTracker
    @Published private(set) var snoozeUntil: Date?
    @Published private(set) var notice: String?
    /// True once the person has turned banners off in System Settings: only
    /// they can turn them back on there. False while macOS was never asked.
    @Published private(set) var needsSystemSettings = false
    private let defaults: UserDefaults
    private var checking = false
    private var askedThisLaunch = false
    static let deniedNotice = "Banners for Usage HUD are off in System Settings › Notifications."
    static let notAskedNotice = "Usage HUD hasn't been allowed to show reset banners yet."
    private static let notificationsSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    private let key = "usageHUD.resetPing."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = Set(defaults.stringArray(forKey: "usageHUD.resetPing.enabled") ?? [])
        tracker = defaults.data(forKey: "usageHUD.resetPing.tracker")
            .flatMap { try? JSONDecoder().decode(ResetPingTracker.self, from: $0) } ?? ResetPingTracker()
        snoozeUntil = defaults.object(forKey: "usageHUD.resetPing.snooze") as? Date
        super.init()
    }

    func setEnabled(_ provider: String, _ value: Bool) {
        if value {
            enabled.insert(provider)
            Task { await requestPermission() }
        } else {
            enabled.remove(provider)
            tracker.watches = tracker.watches.filter { $0.value.provider != provider }
        }
        save()
    }

    /// The panel's fix button. macOS lists an app under Notifications only
    /// after it asks, so a never-asked app is asked now (the system prompt);
    /// one the person switched off goes to the Settings page instead.
    func fixPermission() {
        Task {
            // Ask first even when macOS reports "denied": an app it never
            // registered also reads as denied, and only an ask lists it.
            await requestPermission()
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            if status == .denied, let url = Self.notificationsSettingsURL {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func requestPermission() async {
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
            needsSystemSettings = !allowed
            notice = allowed ? nil : Self.deniedNotice
        } catch {
            // Keep the real reason: an unsigned or ad-hoc build is refused
            // here and never appears in System Settings at all.
            needsSystemSettings = false
            notice = "macOS would not register Usage HUD for banners: \(error.localizedDescription)"
        }
    }

    func snooze(now: Date = Date()) {
        snoozeUntil = now.addingTimeInterval(3600)
        save()
    }

    func resume() {
        snoozeUntil = nil
        save()
    }

    /// Called from the running app's existing refresh, including while its panel is closed.
    func process(_ snapshots: [UsageSnapshot]) {
        guard !enabled.isEmpty, !checking else { return }
        checking = true
        Task {
            defer { checking = false }
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            var status = await center.notificationSettings().authorizationStatus
            // Pings were switched on but macOS was never asked (or the ask was
            // lost to an earlier build, which reads as "denied"): ask once per
            // launch so the app gets listed in System Settings. A real "off"
            // in Settings makes this ask return false with no prompt.
            if status == .notDetermined || status == .denied, !askedThisLaunch {
                askedThisLaunch = true
                await requestPermission()
                status = await center.notificationSettings().authorizationStatus
            }
            let authorized = status == .authorized || status == .provisional
            switch status {
            case .authorized, .provisional:
                notice = nil
                needsSystemSettings = false
            case .denied:
                notice = Self.deniedNotice
                needsSystemSettings = true
            default:
                // Keep a specific refusal reason from requestPermission.
                if notice == nil || notice == Self.deniedNotice { notice = Self.notAskedNotice }
                needsSystemSettings = false
            }
            let now = Date()
            let connected = ProviderPreferences.selection().connected
            let pings = tracker.observe(snapshots, enabled: enabled.intersection(connected),
                                        snoozed: !authorized || (snoozeUntil.map { $0 > now } ?? false), now: now)
            // Persist deduplication before submission so a restart cannot repeat a ping.
            save()
            for ping in pings {
                guard enabled.contains(ping.provider) else { continue }
                let content = UNMutableNotificationContent()
                content.title = "\(UsageInsights.label(for: ping.provider)) window reset"
                content.body = "\(ping.label.capitalized) is back · \(Int(ping.used))% used. Other limits may still apply."
                // Intentionally no sound or badge.
                do {
                    try await center.add(UNNotificationRequest(identifier: "reset.\(ping.id)", content: content, trigger: nil))
                } catch {
                    notice = "Reset detected, but the banner could not be delivered: \(error.localizedDescription)"
                }
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    private func save() {
        defaults.set(Array(enabled).sorted(), forKey: key + "enabled")
        defaults.set(try? JSONEncoder().encode(tracker), forKey: key + "tracker")
        defaults.set(snoozeUntil, forKey: key + "snooze")
    }
}

/// Reset-ping rows for the Settings window's grouped form: one labeled
/// switch per lane, then snooze, live watches, any notice and today's resets.
struct ResetPingCard: View {
    @ObservedObject var controller: ResetPingController
    let providers: [String]

    var body: some View {
        ForEach(providers, id: \.self) { provider in
            Toggle("Ping when \(UsageInsights.label(for: provider)) resets", isOn: Binding(
                get: { controller.enabled.contains(provider) },
                set: { controller.setEnabled(provider, $0) }
            ))
        }
        if providers.isEmpty {
            Text("Show a lane to get reset pings for it.")
                .foregroundStyle(.secondary)
        }
        if !controller.enabled.isEmpty {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if let until = controller.snoozeUntil, until > context.date {
                    LabeledContent {
                        Button("Resume") { controller.resume() }
                    } label: {
                        Text("Pings snoozed")
                        Text("Until \(until.formatted(date: .omitted, time: .shortened))")
                    }
                } else {
                    LabeledContent {
                        Button("Snooze 1 hour") { controller.snooze() }
                    } label: {
                        Text("Snooze")
                        Text("Holds every ping for one hour.")
                    }
                }
            }
        }
        ForEach(controller.tracker.watches.values.sorted { $0.reset < $1.reset }) { watch in
            LabeledContent("\(UsageInsights.label(for: watch.provider)) · \(watch.label)") {
                if watch.reset > Date() {
                    Text(watch.reset, style: .timer).monospacedDigit()
                } else {
                    Text("Waiting for a fresh reading").foregroundStyle(.secondary)
                }
            }
        }
        if let notice = controller.notice {
            LabeledContent {
                Button(controller.needsSystemSettings ? "Open Settings" : "Allow") { controller.fixPermission() }
            } label: {
                Label {
                    Text(notice).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
        let today = controller.tracker.history.filter { Calendar.current.isDateInToday($0.date) }
        if !today.isEmpty {
            LabeledContent("Resets today") {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(today.prefix(3)) { ping in
                        Text("\(ping.date.formatted(date: .omitted, time: .shortened)) · \(UsageInsights.label(for: ping.provider)) \(ping.label)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

