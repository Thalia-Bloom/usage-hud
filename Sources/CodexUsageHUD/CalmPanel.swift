import Foundation

// ============================================================================
//  Calm panel with rewards (Glyph's "B plus C", Nov 11 2026): the answer
//  first in plain words, one row per plan with the most room on top, color
//  only where a plan needs a look, and a small reward when a plan comes back.
//  Pure model here so every rule is testable; the views are in UsageView.
// ============================================================================

/// The one color a plan's row and menu-bar gauge may wear.
enum CalmTone: Equatable {
    case calm    // gray: nothing to look at
    case hot     // amber: on pace to run out before the reset
    case spent   // red: 90% used or more
    case back    // green: just reset, until it passes 10% used
    case dim     // no current reading

    static func make(_ pace: LanePace, old: Bool, back: Bool) -> CalmTone {
        guard let used = pace.used, !old, !pace.historical else { return .dim }
        if back, used < 10 { return .back }
        if used >= 90 { return .spent }
        if ["RUNNING HOT", "5H FULL", "5H TIGHT"].contains(pace.status) { return .hot }
        return .calm
    }

    var usable: Bool { self == .calm || self == .hot || self == .back }
}

struct CalmLane: Equatable {
    var id: String
    var name: String
    var used: Double?
    var tone: CalmTone
    /// Short reset ("Wed 3 PM", "in 2h 10m").
    var reset: String?
}

enum CalmHeadline {
    /// A plan that just came back first, then the most room, then the rest.
    static func sorted(_ lanes: [CalmLane]) -> [CalmLane] {
        func key(_ l: CalmLane) -> (Int, Int, Double) {
            (l.tone == .back ? 0 : 1, l.tone == .dim ? 1 : 0, l.used ?? 1000)
        }
        return lanes.sorted { key($0) < key($1) }
    }

    /// The headline and the one line under it. `back` is a plan whose
    /// comeback the panel hasn't shown since it was last closed.
    static func make(_ lanes: [CalmLane], back: CalmLane? = nil) -> (title: String, sub: String?) {
        let spent = lanes.filter { $0.tone == .spent }.map(\.name)
        let spentLine = spentSentence(lanes)
        if let back {
            return ("\(back.name) is back.", back.reset.map { "Fresh limit. Full allowance until \($0)." } ?? "Fresh limit.")
        }
        guard let best = sorted(lanes).first(where: { $0.tone.usable }) else {
            if spent.isEmpty { return ("Waiting for fresh readings.", nil) }
            let first = lanes.filter { $0.tone == .spent && $0.reset != nil }.first
            let allFull = lanes.allSatisfy { $0.tone != .spent || isFull($0) }
            return (allFull ? "Everything is spent." : "Everything is almost spent.",
                    first.map { "\($0.name) comes back first, \($0.reset!)." })
        }
        let title = lanes.count == 1 ? "\(best.name) has room." : "Use \(best.name) next."
        if let spentLine { return (title, spentLine) }
        if best.tone == .hot { return (title, "It's running hot, so pace it.") }
        let dim = lanes.filter { $0.tone == .dim }.map(\.name)
        if !dim.isEmpty { return (title, "\(list(dim)) \(dim.count == 1 ? "needs a fresh reading." : "need fresh readings.")") }
        return (title, lanes.count == 1 ? nil : "Every plan has room.")
    }

    /// The open row's pace sentence, built from the lane's own lines:
    /// "Running hot." then "Runs out ~1 AM at this pace. 1.2K credits left."
    /// The reset sits in the row already, so it is not repeated.
    static func detail(_ lines: LaneLines, status: String, age: String? = nil, fable: String? = nil) -> (head: String?, rest: String) {
        func parts(_ s: String?) -> [String] { (s ?? "").components(separatedBy: " · ").filter { !$0.isEmpty } }
        var head = parts(lines.status).first
        var rest = Array(parts(lines.status).dropFirst()) + parts(lines.primary).filter { !$0.hasPrefix("resets ") }
        if lines.primaryIsGap, head == nil, !rest.isEmpty { head = rest.removeFirst() }
        if head == nil, rest.isEmpty { head = status == "ON PACE" ? "On pace with the clock" : "Room to spare" }
        if let fable { rest.append("Fable has used \(fable) of its own week") }
        if let age { rest.append("Read \(age) ago") }
        let sentence = rest.map { ($0.prefix(1).uppercased() + $0.dropFirst()) + "." }.joined(separator: " ")
        return (head.map { $0.prefix(1).uppercased() + $0.dropFirst() }, sentence)
    }

    /// 100% is "spent", the same point the row first shows "100%" (99.9
    /// still shows 99%); 90 to 99 is "almost spent".
    static func isFull(_ lane: CalmLane) -> Bool { (lane.used ?? 0) >= 100 }

    /// "Codex is spent until it resets." / "Claude and Gemini are almost spent
    /// until they reset." / "Codex is spent and Claude is almost spent until
    /// they reset."
    static func spentSentence(_ lanes: [CalmLane]) -> String? {
        let red = lanes.filter { $0.tone == .spent }
        guard !red.isEmpty else { return nil }
        let full = red.filter(isFull).map(\.name), near = red.filter { !isFull($0) }.map(\.name)
        func clause(_ names: [String], _ word: String) -> String? {
            names.isEmpty ? nil : "\(list(names)) \(names.count == 1 ? "is" : "are") \(word)"
        }
        let clauses = [clause(full, "spent"), clause(near, "almost spent")].compactMap { $0 }
        return clauses.joined(separator: " and ") + (red.count == 1 ? " until it resets." : " until they reset.")
    }

    static func list(_ names: [String]) -> String {
        names.count <= 2 ? names.joined(separator: " and ")
            : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}

/// Remembers each plan's reset so the panel can celebrate one coming back:
/// the bar drains and turns green, the row moves to the top, and the
/// headline says so until the panel closes. Green lasts until 10% used.
@MainActor
final class ComeBack: ObservableObject {
    struct Mark: Codable, Equatable {
        var resetAt: Date
        var lastUsed: Double?
        var backAt: Date?
        /// Used % before the reset; the bar drains from here.
        var before: Double?
        var seen = false
        var played = false
    }

    static let shared = ComeBack()
    private static let key = "hud.comeBack"
    @Published private(set) var marks: [String: Mark] = [:]

    init() {
        if let p = ProcessInfo.processInfo.environment["CODEX_USAGE_HUD_SNAPSHOT_BACK"] {
            marks[p] = Mark(resetAt: Date(), lastUsed: 4, backAt: Date(), before: 92)
        } else if let data = UserDefaults.standard.data(forKey: Self.key) {
            marks = (try? JSONDecoder().decode([String: Mark].self, from: data)) ?? [:]
        }
    }

    nonisolated static func step(_ old: Mark?, resetAt: Date, used: Double?, now: Date) -> Mark {
        guard var m = old else { return Mark(resetAt: resetAt, lastUsed: used) }
        if resetAt.timeIntervalSince(m.resetAt) > 3600, let used, used < 10 {
            return Mark(resetAt: resetAt, lastUsed: used, backAt: now, before: m.lastUsed ?? 100)
        }
        m.resetAt = max(m.resetAt, resetAt)
        if let used { m.lastUsed = used; if used >= 10 { m.backAt = nil } }
        return m
    }

    func observe(_ snapshots: [UsageSnapshot], now: Date = Date()) {
        var next = marks
        for snap in snapshots where snap.provider.lowercased() != "local" {
            guard let w = snap.week ?? snap.currentSession,
                  let reset = UsageInsights.resetDate(for: w, now: now) else { continue }
            let p = snap.provider.lowercased()
            next[p] = Self.step(next[p], resetAt: reset, used: w.usedPct, now: now)
        }
        update(next)
    }

    func back(_ provider: String) -> Mark? { marks[provider].flatMap { $0.backAt == nil ? nil : $0 } }
    func played(_ provider: String) { var next = marks; next[provider]?.played = true; update(next) }
    func panelClosed() { update(marks.mapValues { var m = $0; if m.backAt != nil { m.seen = true; m.played = true }; return m }) }

    private func update(_ next: [String: Mark]) {
        guard next != marks else { return }
        marks = next
        guard !SnapshotMode.enabled, let data = try? JSONEncoder().encode(next) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
