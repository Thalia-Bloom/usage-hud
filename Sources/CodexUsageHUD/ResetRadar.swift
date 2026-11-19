import Foundation

/// Tracks window resets and expiring unused allowance so available resets
/// and soon-to-expire room stay visible at a glance.
enum ResetRadar {
    enum Kind: String, Equatable, Sendable {
        case available
        case useSoon
        case upcoming
    }

    struct Item: Identifiable, Equatable, Sendable {
        var id: String
        var provider: String
        var windowKey: String
        var kind: Kind
        var title: String
        var detail: String
        var resetAt: Date?
    }

    private struct Candidate {
        var item: Item
        var rank: Int
        var sortDate: Date
        var isPriorityUpcoming: Bool
    }

    static func items(
        snapshots: [UsageSnapshot],
        visibleProviders: [String],
        marks: [String: ResetMemory.Mark] = [:],
        now: Date = Date()
    ) -> [Item] {
        var available: [Candidate] = []
        var useSoon: [Candidate] = []
        var priorityUpcoming: [Candidate] = []
        var otherUpcoming: [Candidate] = []

        for (pIndex, provider) in visibleProviders.enumerated() where provider.lowercased() != "local" {
            let pid = provider.lowercased()
            guard let snap = UsageInsights.snapshot(for: pid, in: snapshots) else { continue }
            let name = UsageInsights.label(for: pid)
            let fresh = UsageInsights.laneFreshness(for: snap, now: now)
            let geminiDaily = pid == "gemini" && snap.week?.label?.lowercased().contains("week") != true
            let specs: [(key: String, label: String, metric: UsageSnapshot.WindowMetric?, duration: TimeInterval)] = [
                ("week", geminiDaily ? "daily" : "weekly", snap.week, geminiDaily ? 24 * 3600 : 7 * 86_400),
                ("fable", "Fable", snap.weekFable, 7 * 86_400),
                ("5h", "5-hour", snap.currentSession, 5 * 3600),
            ]

            for (wIndex, spec) in specs.enumerated() {
                guard let metric = spec.metric else { continue }
                let id = "\(pid).\(spec.key)"
                let title = "\(name) \(spec.label)"
                let reset = UsageInsights.resetDate(for: metric, now: now)

                if !fresh.isOld, metric.isExpired, (metric.lastKnownUsedPct ?? 0) >= 20 {
                    priorityUpcoming.append(Candidate(
                        item: Item(id: id, provider: pid, windowKey: spec.key, kind: .upcoming,
                                   title: title, detail: "Reset passed · waiting for reading", resetAt: reset),
                        rank: pIndex * 10 + wIndex,
                        sortDate: reset ?? now,
                        isPriorityUpcoming: true
                    ))
                    continue
                }

                guard let used = metric.usedPct, let reset else { continue }
                let remaining = reset.timeIntervalSince(now)
                if remaining <= 0 {
                    if !fresh.isOld, used >= 20 {
                        priorityUpcoming.append(Candidate(
                            item: Item(id: id, provider: pid, windowKey: spec.key, kind: .upcoming,
                                       title: title, detail: "Reset passed · waiting for reading", resetAt: reset),
                            rank: pIndex * 10 + wIndex,
                            sortDate: reset,
                            isPriorityUpcoming: true
                        ))
                    }
                    continue
                }

                let leftText = StatusItemText.percent(max(0, 100 - used))
                let short = laneResetText(metric.resetLabel, metric.resetAt, now: now) ?? ""

                if !fresh.isOld, let resetAgo = freshResetAge(
                    mark: marks[id], key: spec.key, duration: spec.duration,
                    remaining: remaining, used: used, now: now
                ) {
                    let agoText = LaneFreshness.short(max(60, resetAgo))
                    available.append(Candidate(
                        item: Item(id: id, provider: pid, windowKey: spec.key, kind: .available,
                                   title: title, detail: "Reset \(agoText) ago · \(leftText) left", resetAt: reset),
                        rank: pIndex * 10 + wIndex,
                        sortDate: reset,
                        isPriorityUpcoming: false
                    ))
                    continue
                }

                if !fresh.isOld, isExpiringSoon(key: spec.key, duration: spec.duration, remaining: remaining, used: used) {
                    useSoon.append(Candidate(
                        item: Item(id: id, provider: pid, windowKey: spec.key, kind: .useSoon,
                                   title: title, detail: "\(leftText) left · resets \(short)", resetAt: reset),
                        rank: pIndex * 10 + wIndex,
                        sortDate: reset,
                        isPriorityUpcoming: false
                    ))
                    continue
                }

                let verb = used >= 99.5 ? "Unlocks" : "Resets"
                let detail = remaining <= 3 * 3600 ? "\(verb) \(short)" : "\(verb) \(short) (\(shortSpan(remaining)))"
                if used > 80 {
                    priorityUpcoming.append(Candidate(
                        item: Item(id: id, provider: pid, windowKey: spec.key, kind: .upcoming,
                                   title: title, detail: detail, resetAt: reset),
                        rank: pIndex * 10 + wIndex,
                        sortDate: reset,
                        isPriorityUpcoming: true
                    ))
                } else if !fresh.isOld {
                    otherUpcoming.append(Candidate(
                        item: Item(id: id, provider: pid, windowKey: spec.key, kind: .upcoming,
                                   title: title, detail: detail, resetAt: reset),
                        rank: pIndex * 10 + wIndex,
                        sortDate: reset,
                        isPriorityUpcoming: false
                    ))
                }
            }
        }

        available.sort { $0.rank < $1.rank }
        useSoon.sort { ($0.sortDate, $0.rank) < ($1.sortDate, $1.rank) }
        priorityUpcoming.sort { ($0.sortDate, $0.rank) < ($1.sortDate, $1.rank) }
        otherUpcoming.sort { ($0.sortDate, $0.rank) < ($1.sortDate, $1.rank) }

        var chosen: [Item] = (available + useSoon + priorityUpcoming).map(\.item)
        if chosen.count < 2 {
            let seen = Set(chosen.map(\.id))
            for candidate in otherUpcoming where !seen.contains(candidate.item.id) {
                chosen.append(candidate.item)
                if chosen.count >= 3 { break }
            }
        }
        return Array(chosen.prefix(4))
    }

    private static func freshResetAge(
        mark: ResetMemory.Mark?,
        key: String,
        duration: TimeInterval,
        remaining: TimeInterval,
        used: Double,
        now: Date
    ) -> TimeInterval? {
        let freshWindow: TimeInterval = key == "5h" ? 90 * 60 : 12 * 3600
        if let observed = mark?.resetAtTime {
            let age = now.timeIntervalSince(observed)
            if age >= 0, age <= freshWindow, used < 25 {
                return age
            }
        }
        if key != "5h", duration == 7 * 86_400, used < 20 {
            let elapsed = duration - remaining
            if elapsed >= 0, elapsed <= 12 * 3600 {
                return elapsed
            }
        }
        return nil
    }

    private static func isExpiringSoon(key: String, duration: TimeInterval, remaining: TimeInterval, used: Double) -> Bool {
        if key == "5h" {
            return remaining <= 3600 && used >= 5 && used <= 70
        }
        if duration == 7 * 86_400 || key == "week" || key == "fable" {
            return remaining <= 24 * 3600 && used <= 80
        }
        return false
    }

    private static func shortSpan(_ seconds: TimeInterval) -> String {
        let mins = Int((max(0, seconds) / 60).rounded(.up))
        if mins < 60 { return "\(mins)m" }
        let hours = mins / 60
        if hours < 24 {
            let rem = mins % 60
            return rem == 0 ? "\(hours)h" : "\(hours)h \(rem)m"
        }
        let days = hours / 24
        let remHours = hours % 24
        return remHours == 0 ? "\(days)d" : "\(days)d \(remHours)h"
    }
}

/// Remembers each window's reset timestamp and prior usage so fresh rollovers
/// stay visible in ResetRadar until the window gets used.
@MainActor
final class ResetMemory: ObservableObject {
    struct Mark: Codable, Equatable, Sendable {
        var resetAt: Date
        var lastUsed: Double?
        var resetAtTime: Date?
    }

    static let shared = ResetMemory()
    private static let defaultsKey = "usageHUD.resetMemory"
    @Published private(set) var marks: [String: Mark] = [:]

    init(defaults: UserDefaults = .standard) {
        if !SnapshotMode.enabled, let data = defaults.data(forKey: Self.defaultsKey) {
            marks = (try? JSONDecoder().decode([String: Mark].self, from: data)) ?? [:]
        }
    }

    nonisolated static func step(_ old: Mark?, resetAt: Date, used: Double?, now: Date) -> Mark {
        guard var mark = old else {
            return Mark(resetAt: resetAt, lastUsed: used, resetAtTime: nil)
        }
        if resetAt.timeIntervalSince(mark.resetAt) > 1800,
           ((mark.lastUsed ?? 0) >= 15 || mark.resetAt <= now) {
            if let used, used < 25 {
                return Mark(resetAt: resetAt, lastUsed: used, resetAtTime: now)
            }
            return Mark(resetAt: resetAt, lastUsed: used, resetAtTime: nil)
        }
        mark.resetAt = max(mark.resetAt, resetAt)
        if let used {
            mark.lastUsed = used
            if used >= 25 { mark.resetAtTime = nil }
        }
        return mark
    }

    func observe(_ snapshots: [UsageSnapshot], now: Date = Date(), defaults: UserDefaults = .standard) {
        var next = marks
        for snap in snapshots where snap.provider.lowercased() != "local" {
            let pid = snap.provider.lowercased()
            let windows: [(String, UsageSnapshot.WindowMetric?)] = [
                ("week", snap.week),
                ("5h", snap.currentSession),
                ("fable", snap.weekFable),
            ]
            for (key, metric) in windows {
                guard let metric, !metric.isExpired, !metric.isUnknown,
                      let reset = UsageInsights.resetDate(for: metric, now: now) else { continue }
                let id = "\(pid).\(key)"
                next[id] = Self.step(next[id], resetAt: reset, used: metric.usedPct, now: now)
            }
        }
        guard next != marks else { return }
        marks = next
        guard !SnapshotMode.enabled, let data = try? JSONEncoder().encode(next) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
