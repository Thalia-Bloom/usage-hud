import Foundation

/// The hero line at the top of the panel: one verdict pill plus a sentence
/// that names the lane it is about. Pure so the rules are testable.
///
/// Rules:
/// - The verdict names the primary lane ("Codex: clear to build"), never a
///   hard-coded provider, so a Codex-only Mac does not read "Claude: ...".
/// - A GO needs that lane's own reading to be fresh: checked in the last
///   15 minutes and its windows not old. Otherwise it is a neutral CHECK
///   that says why ("Claude: reading is 3h old").
/// - A GO never sits beside a lane that says it is running hot or nearly
///   out: pace outranks room, so the pill drops to WATCH and the sentence
///   says why.
enum HeroVerdict {
    struct Result: Equatable {
        var mode: String
        var tagline: String
    }

    /// Lane pace statuses that contradict a GO.
    static let pressingStatuses: Set<String> = ["RUNNING HOT", "5H TIGHT", "5H FULL", "ALMOST SPENT"]

    /// Whether the verdict lane's reading can carry a GO, and if not, the
    /// plain reason the CHECK line gives.
    struct Reading: Equatable {
        var fresh: Bool
        var why: String?
    }

    /// The GO gate. The writer checking in recently is not enough: the
    /// windows themselves must not be old (a fresh check-in can carry a
    /// 3-hour-old window), and the lane must not be failing to refresh.
    static func reading(for snapshot: UsageSnapshot?, now: Date = Date()) -> Reading {
        guard let snapshot else { return Reading(fresh: false, why: nil) }
        let lane = UsageInsights.laneFreshness(for: snapshot, now: now)
        if lane.isOld {
            if lane.issue != nil { return Reading(fresh: false, why: lane.issue) }
            return Reading(fresh: false, why: lane.ageShort.map { "reading is \($0) old" })
        }
        guard UsageInsights.isReadingFresh(snapshot, within: LaneFreshness.liveSeconds, now: now) else {
            let age = UsageInsights.capturedDate(snapshot).map { LaneFreshness.short(now.timeIntervalSince($0)) }
            return Reading(fresh: false, why: age.map { "reading is \($0) old" })
        }
        return Reading(fresh: true, why: nil)
    }

    static func resolve(mode raw: String, laneName: String?, readingFresh: Bool, paceStatus: String?,
                        staleReason: String? = nil) -> Result {
        let mode = raw.lowercased()
        let name = laneName ?? "Usage"
        if mode == "green" {
            guard readingFresh else {
                return Result(mode: "check", tagline: "\(name): \(staleReason ?? "check reading")")
            }
            if let paceStatus, pressingStatuses.contains(paceStatus) {
                return Result(mode: "yellow", tagline: "\(name): \(pressingTagline(paceStatus))")
            }
            return Result(mode: "green", tagline: "\(name): clear to build")
        }
        if ["yellow", "orange"].contains(mode), let paceStatus, pressingStatuses.contains(paceStatus) {
            return Result(mode: mode, tagline: "\(name): \(pressingTagline(paceStatus))")
        }
        return Result(mode: mode, tagline: defaultTagline(mode, name: name))
    }

    static func pressingTagline(_ status: String) -> String {
        switch status {
        case "5H FULL": return "5-hour window full"
        case "5H TIGHT": return "5-hour window nearly full"
        case "ALMOST SPENT": return "almost spent"
        default: return "running hot"
        }
    }

    static func defaultTagline(_ mode: String, name: String) -> String {
        switch mode {
        case "yellow": return "\(name): watch your spend"
        case "orange": return "\(name): conserve"
        case "red": return "\(name): nearly out"
        case "freeze": return "\(name): spent until reset"
        case "check": return "\(name): check reading"
        default: return "Waiting on data"
        }
    }

    /// One lane the panel can read about: its name, how much of its window
    /// is spent, its pace status, and whether its reading is current.
    struct Lane: Equatable {
        var name: String
        var used: Double?
        var paceStatus: String
        var fresh: Bool
    }

    /// "Which tool should I use right now?" When the primary lane is under
    /// pressure, name the other current lane with the most room, so the
    /// verdict comes with a next move instead of only a warning. Returns nil
    /// when the primary lane is fine or no other lane clearly has room.
    static func alternative(mode: String, primary: String?, lanes: [Lane]) -> String? {
        guard ["yellow", "orange", "red", "freeze"].contains(mode.lowercased()) else { return nil }
        let blocked: Set<String> = pressingStatuses.union(["✓ SPENT", "NO DATA", "WAIT", "RESET PASSED"])
        let best = lanes
            .filter { $0.name != primary && $0.fresh && !blocked.contains($0.paceStatus) }
            .compactMap { lane in lane.used.map { (lane, $0) } }
            .filter { $0.1 < 60 }
            .min { $0.1 < $1.1 }
        guard let (lane, used) = best else { return nil }
        return "\(lane.name) has room · \(Int(used.rounded()))% used"
    }
}

