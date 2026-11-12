import AppKit
import Foundation

/// A usage-endpoint cooldown needs time, not another sign-in or setup run.
struct RateLimitRecovery {
    let note: String
    let detail: String

    static func make(status: UsageSnapshot.ProviderHealth?, now: Date) -> RateLimitRecovery? {
        guard status?.status?.lowercased() == "rate_limited" else { return nil }
        if let retryAt = UsageInsights.parseDate(status?.retryAt), retryAt > now {
            let minutes = max(1, Int(ceil(retryAt.timeIntervalSince(now) / 60)))
            let useHours = minutes >= 60
            let amount = useHours ? Int(ceil(Double(minutes) / 60)) : minutes
            let unit = useHours ? "hour" : "minute"
            let suffix = useHours ? "h" : "m"
            return RateLimitRecovery(note: "retry in \(amount)\(suffix)",
                detail: "Usage requests are temporarily rate-limited. Keep Usage HUD open; it will retry automatically in about \(amount) \(unit)\(amount == 1 ? "" : "s"). No sign-in or setup change is needed.")
        }
        return RateLimitRecovery(note: "usage rate-limited",
            detail: "The last usage check was rate-limited. Keep Usage HUD open for automatic retries. If the reading stays old, run diagnostics in Settings.")
    }
}

/// One freshness vocabulary for the whole panel. The header pill, each lane
/// row, its source tag, the detail card and the verdict all read this, so
/// the same reading can never be "live" in one place and "old" in another.
///
/// - live: read in the last 10 minutes (Claude and Codex are read every 5).
/// - recent: older than that but inside the lane's normal refresh cadence;
///   shown as "updated 25m ago".
/// - old: past that cadence, or the lane's own writer says it is stale.
///
/// A lane can also carry an `issue` (sign-in needed, refresh failing) while
/// its numbers are still current; that needs a look but is not "old".
struct LaneFreshness: Equatable {
    enum State: Int, Comparable {
        case live = 0
        case recent = 1
        case old = 2

        static func < (lhs: State, rhs: State) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var state: State
    /// Seconds since the number on screen was read; nil when unknown.
    var age: TimeInterval?
    var isNotSetUp = false
    /// Short plain issue for the row and header: "not refreshing",
    /// "sign in again". nil when the lane has nothing wrong.
    var issue: String? = nil
    /// The writer's own words about the issue, for the tooltip.
    var issueDetail: String? = nil

    static let liveSeconds: TimeInterval = 10 * 60

    var isOld: Bool { state == .old }
    var needsAttention: Bool { !isNotSetUp && (state == .old || issue != nil) }

    /// The vocabulary itself: "live", "updated 25m ago" or "old".
    var label: String {
        if isNotSetUp { return "not set up" }
        switch state {
        case .live: return "live"
        case .recent: return age.map { "updated \(Self.short($0)) ago" } ?? "updated"
        case .old: return "old"
        }
    }

    /// What a lane row adds to its second line. Nil when live and healthy.
    var note: String? {
        if isNotSetUp { return "not set up" }
        if let issue { return issue }
        switch state {
        // Every number says how old it is, live ones included, so a
        // timed refresh never passes for a live feed.
        case .live: return age.map { "\(Self.short($0)) ago" }
        case .recent: return label
        case .old: return age.map { "updated \(Self.short($0)) ago" } ?? "no update time"
        }
    }

    /// "3h", "25m", "2d" — nil when the age is unknown.
    var ageShort: String? { age.map(Self.short) }

    /// "3 hours", "25 minutes" — for VoiceOver.
    var ageSpoken: String? { age.map(Self.spoken) }

    static func make(readAt: Date?, oldAfter: TimeInterval, now: Date = Date()) -> LaneFreshness {
        guard let readAt else { return LaneFreshness(state: .old, age: nil) }
        let age = max(0, now.timeIntervalSince(readAt))
        if age <= liveSeconds { return LaneFreshness(state: .live, age: age) }
        if age <= oldAfter { return LaneFreshness(state: .recent, age: age) }
        return LaneFreshness(state: .old, age: age)
    }

    static func short(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "\(max(1, s))s" }
        if s < 3_600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3_600)h" }
        return "\(s / 86_400)d"
    }

    static func spoken(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        if s < 60 { return "less than a minute" }
        if s < 3_600 { return unit(s / 60, "minute") }
        if s < 86_400 { return unit(s / 3_600, "hour") }
        return unit(s / 86_400, "day")
    }
}

extension UsageInsights {
    /// A reading turns old past this age. Every lane is read at least every
    /// 30 minutes (Claude and Codex every 5, Gemini every 30), so a 5-hour
    /// window older than an hour means its reader stopped; a weekly one is
    /// given 3 hours.
    static func oldReadingSeconds(for snapshot: UsageSnapshot) -> TimeInterval {
        snapshot.currentSession?.usedPct != nil ? 3_600 : 3 * 3_600
    }

    /// When the number on screen was read: the windows' own stamp when the
    /// lane has windows, otherwise when its writer last checked in. The
    /// older of the two wins, so a fresh check-in can't hide an old window.
    static func readingDate(_ snapshot: UsageSnapshot?) -> Date? {
        guard let snapshot else { return nil }
        let captured = capturedDate(snapshot)
        guard hasWindowData(snapshot) else { return captured }
        guard let window = windowEventDate(snapshot) else { return captured }
        guard let captured else { return window }
        return min(window, captured)
    }

    /// The single freshness answer for a lane. See `LaneFreshness`.
    static func laneFreshness(for snapshot: UsageSnapshot?, now: Date = Date()) -> LaneFreshness {
        guard let snapshot else { return LaneFreshness(state: .old, age: nil) }
        if snapshot.provider == "grok", snapshot.health?.isNotSetUp == true,
           snapshot.windows.isEmpty, snapshot.week == nil, snapshot.currentSession == nil {
            return LaneFreshness(state: .recent, age: nil, isNotSetUp: true)
        }
        // Local model tokens are recounted from the logs on every read, so
        // the count is current even when the last request was days ago.
        if snapshot.provider.lowercased() == "local" {
            return LaneFreshness(state: .live, age: 0)
        }
        var fresh = LaneFreshness.make(readAt: readingDate(snapshot),
                                       oldAfter: oldReadingSeconds(for: snapshot), now: now)

        // A revoked or missing sign-in can't fix itself, even while the
        // live windows keep the numbers current. Checked before the writer's
        // health, which also goes amber for it and would only say "not
        // refreshing" when the fix is to sign in.
        // An expired token isn't a sign-out: Claude Code renews it the next
        // time it runs, and the lane recovers by itself within a minute.
        if snapshot.officialUsageStatus?.status?.lowercased() == "token_expired" {
            if fresh.state == .live { fresh.state = .recent }
            fresh.issue = "open Claude Code once"
            fresh.issueDetail = snapshot.officialUsageStatus?.message
            return fresh
        }
        if snapshot.officialUsageStatus?.status?.lowercased() == "keychain_locked" {
            if snapshot.health?.isWarning == true { fresh.state = .old }
            fresh.issue = "allow Keychain access"
            fresh.issueDetail = snapshot.officialUsageStatus?.message ?? snapshot.health?.reason
            return fresh
        }
        if let status = snapshot.officialUsageStatus?.status?.lowercased(),
           status == "unauthorized" || status == "no_credential" {
            if snapshot.health?.isWarning == true { fresh.state = .old }
            fresh.issue = "sign in again"
            fresh.issueDetail = snapshot.officialUsageStatus?.message ?? snapshot.officialUsageStatus?.reason ?? snapshot.health?.reason
            return fresh
        }
        // Either source can carry the cooldown; the official status saying "ok" mustn't hide a rate-limited writer.
        if let recovery = RateLimitRecovery.make(status: snapshot.officialUsageStatus, now: now)
            ?? RateLimitRecovery.make(status: snapshot.providerHealth, now: now),
           fresh.state != .live || snapshot.health?.isWarning == true {
            if snapshot.health?.isWarning == true { fresh.state = .old }
            fresh.issue = recovery.note
            fresh.issueDetail = recovery.detail
            return fresh
        }
        // The lane's own writer says its numbers are stale: believe it.
        if let health = snapshot.health, health.isWarning {
            fresh.state = .old
            fresh.issue = "not refreshing"
            fresh.issueDetail = health.reason
            return fresh
        }
        // Any other failed check matters only once the numbers stop moving.
        if fresh.state != .live, headerHasHealthWarning(snapshot, now: now) {
            let warning = snapshot.officialUsageStatus?.isWarning == true ? snapshot.officialUsageStatus : snapshot.providerHealth
            fresh.issue = "not refreshing"
            fresh.issueDetail = warning?.message ?? warning?.reason ?? warning?.status
        }
        return fresh
    }
}

/// What the header pill says: the worst visible lane, in the same words the
/// rows use. "live" only when every lane is live.
struct HeaderStatus: Equatable {
    enum Tone: Equatable { case live, recent, attention, idle }

    let text: String
    let tone: Tone
    let help: String

    struct Lane: Equatable {
        let name: String
        let freshness: LaneFreshness
    }

    static func make(lanes: [Lane]) -> HeaderStatus {
        guard !lanes.isEmpty else {
            return HeaderStatus(text: "not connected", tone: .idle,
                                help: "No readings yet. Click Set up to connect the tools found on this Mac.")
        }
        let attention = lanes.filter { $0.freshness.needsAttention }
        if attention.count == 1, let lane = attention.first {
            // "sign in again" is the fix, so it beats "old" even on an old lane.
            let issue = lane.freshness.issue
            let actionable = issue == "sign in again" || issue == "open Claude Code once" || issue == "allow Keychain access" || issue == "usage rate-limited" || issue?.hasPrefix("retry in ") == true
            let what = actionable ? (issue ?? "old") : (lane.freshness.isOld ? "old" : (issue ?? "old"))
            return HeaderStatus(text: "\(lane.name) · \(what)", tone: .attention,
                                help: "\(lane.name): \(describe(lane.freshness)). Other lanes are current.")
        }
        if attention.count > 1 {
            let allOld = attention.allSatisfy { $0.freshness.isOld }
            let lines = attention.map { "\($0.name): \(describe($0.freshness))" }
            return HeaderStatus(text: allOld ? "\(attention.count) lanes old" : "\(attention.count) lanes need a look",
                                tone: .attention, help: lines.joined(separator: "\n"))
        }
        let recent = lanes.filter { $0.freshness.state == .recent }
        if let oldest = recent.max(by: { ($0.freshness.age ?? 0) < ($1.freshness.age ?? 0) }) {
            let text = recent.count == 1 ? "\(oldest.name) · \(oldest.freshness.label)" : oldest.freshness.label
            let lines = recent.map { "\($0.name) \($0.freshness.label)" }
            return HeaderStatus(text: text, tone: .recent,
                                help: lines.joined(separator: "\n") + "\nOther lanes are live. These refresh on their own schedule.")
        }
        return HeaderStatus(text: "live", tone: .live, help: "Every lane was read in the last 10 minutes.")
    }

    private static func describe(_ f: LaneFreshness) -> String {
        if let issue = f.issue {
            let detail = f.issueDetail.map { " (\($0))" } ?? ""
            return "\(issue)\(detail)"
        }
        if f.isOld { return f.age.map { "reading is \(LaneFreshness.short($0)) old" } ?? "no update time" }
        return f.label
    }
}

/// Plain-English recovery steps shown when clicking any attention label.
struct LaneRecovery: Equatable {
    let provider: String, title: String, why: String, step: String, command: String?

    static func make(provider: String, snapshot: UsageSnapshot?, freshness: LaneFreshness) -> LaneRecovery? {
        let id = provider.lowercased(), name = UsageInsights.label(for: id)
        guard snapshot == nil || freshness.needsAttention else { return nil }
        let status = (snapshot?.officialUsageStatus?.status ?? snapshot?.providerHealth?.status)?.lowercased()
        if id == "claude" {
            if status == "keychain_locked" {
                return .init(provider: id, title: "Claude needs Keychain access",
                             why: "macOS Keychain blocked background access to Claude Code's local sign-in on this Mac.",
                             step: "Unlock Login Keychain (or click Always Allow if macOS asks), then click Check again.", command: nil)
            }
            if status == "rate_limited" || freshness.issue == "usage rate-limited" || freshness.issue?.hasPrefix("retry in ") == true {
                return .init(provider: id, title: "Claude usage is cooling down",
                             why: freshness.issueDetail ?? "Anthropic temporarily rate-limited usage checks.",
                             step: "Keep Usage HUD open; it retries automatically once the wait ends. No sign-in needed.", command: nil)
            }
            if status == "token_expired" || freshness.issue == "open Claude Code once" {
                return .init(provider: id, title: "Wake Claude Code on this Mac",
                             why: "Claude Code's local sign-in token lasts about 8 hours. Claude Desktop chat and remote Claude Code sessions don't renew this Mac's local CLI token, and Usage HUD never refreshes tokens itself.",
                             step: "Run `claude` once in Terminal on this Mac; this lane catches up within a minute.", command: "claude")
            }
            if status == "no_credential" || status == "unauthorized" || freshness.issue == "sign in again" || snapshot == nil {
                return .init(provider: id, title: "Sign in to Claude Code on this Mac",
                             why: "Claude Desktop chat and remote Claude Code sessions don't sign in or renew this Mac's local `claude` CLI credential.",
                             step: "Run `claude` in Terminal on this Mac (use `/login` if prompted), then click Check again.", command: "claude")
            }
            return .init(provider: id, title: "Refresh Claude on this Mac",
                         why: freshness.issueDetail ?? "The last Claude reading on this Mac is older than expected.",
                         step: "Click Check again below, or run `claude` once in Terminal if local sign-in paused.", command: "claude")
        }
        let cmd: String? = id == "codex" ? "codex" : (id == "grok" ? "grok login" : (id == "gemini" ? "agy" : nil))
        return .init(provider: id, title: "\(name) needs a fresh reading",
                     why: freshness.issueDetail ?? "Usage HUD hasn't received a recent \(name) reading on this Mac.",
                     step: cmd.map { "Run `\($0)` once in Terminal to verify sign-in, then click Check again." } ?? "Click Check again below.", command: cmd)
    }

    static func copyCommand(_ command: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string) }
    static func openTerminal() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
