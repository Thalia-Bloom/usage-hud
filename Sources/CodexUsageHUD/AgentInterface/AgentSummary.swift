import Foundation

/// The agent-facing answer to "how much room does each AI plan on this Mac
/// have?" Pure and Codable so the CLI (`status --json`), the MCP server and
/// tests all share one shape. Versioned: bump `currentSchemaVersion` only for
/// breaking changes; adding a field is not breaking.
///
/// Privacy: built only from percentages, reset times, reading ages and a
/// fixed set of source labels. It never carries tokens, credential paths,
/// snapshot paths, prompts, file contents, or free text a writer put in a
/// snapshot (writer `reason` strings are replaced by notes written here).
struct AgentSummary: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    struct App: Codable, Equatable, Sendable {
        var name: String
        var version: String
    }

    /// The panel's hero verdict, for the lane the panel leads with.
    struct Verdict: Codable, Equatable, Sendable {
        /// GO | WATCH | STOP | CHECK
        var mode: String
        /// Provider id the verdict is about; nil when no lane has data.
        var lane: String?
        var laneName: String?
        var sentence: String

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(mode, forKey: .mode)
            try c.encode(lane, forKey: .lane)
            try c.encode(laneName, forKey: .laneName)
            try c.encode(sentence, forKey: .sentence)
        }
    }

    /// The current lane with the most room (HeroVerdict semantics: a fresh
    /// reading, not pressed or spent, under 60% used, lowest used wins).
    struct Room: Codable, Equatable, Sendable {
        var lane: String
        var laneName: String
        var window: String?
        var usedPercent: Double
        var pace: String
        var resetsAt: String?
        var resetsIn: String?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(lane, forKey: .lane)
            try c.encode(laneName, forKey: .laneName)
            try c.encode(window, forKey: .window)
            try c.encode(usedPercent, forKey: .usedPercent)
            try c.encode(pace, forKey: .pace)
            try c.encode(resetsAt, forKey: .resetsAt)
            try c.encode(resetsIn, forKey: .resetsIn)
        }
    }

    /// One limit window of a lane (5-hour, weekly, daily, or a model-scoped week).
    struct Window: Codable, Equatable, Sendable {
        /// 5h | week | day
        var window: String
        /// Set when the window is limited to one model (Claude's Fable week).
        var scope: String?
        var usedPercent: Double?
        var resetsAt: String?
        var resetsIn: String?
        var pace: String
        /// live | expired | unknown | reset_passed
        var state: String

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(window, forKey: .window)
            try c.encode(scope, forKey: .scope)
            try c.encode(usedPercent, forKey: .usedPercent)
            try c.encode(resetsAt, forKey: .resetsAt)
            try c.encode(resetsIn, forKey: .resetsIn)
            try c.encode(pace, forKey: .pace)
            try c.encode(state, forKey: .state)
        }
    }

    /// One provider lane, headlined by the window the panel shows for it.
    struct Lane: Codable, Equatable, Sendable {
        var provider: String
        var name: String
        var window: String?
        var usedPercent: Double?
        var resetsAt: String?
        var resetsIn: String?
        /// on_pace | running_hot | room | almost_spent | spent | unknown
        var pace: String
        /// The panel's own words for the lane ("RUNNING HOT", "5H TIGHT", "IDLE"…).
        var status: String
        var forecastEmptyAt: String?
        /// official | measured | estimated | unknown
        var confidence: String
        var source: String
        var readingAgeSeconds: Int?
        var readingAge: String?
        var stale: Bool
        var note: String?
        var windows: [Window]

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(provider, forKey: .provider)
            try c.encode(name, forKey: .name)
            try c.encode(window, forKey: .window)
            try c.encode(usedPercent, forKey: .usedPercent)
            try c.encode(resetsAt, forKey: .resetsAt)
            try c.encode(resetsIn, forKey: .resetsIn)
            try c.encode(pace, forKey: .pace)
            try c.encode(status, forKey: .status)
            try c.encode(forecastEmptyAt, forKey: .forecastEmptyAt)
            try c.encode(confidence, forKey: .confidence)
            try c.encode(source, forKey: .source)
            try c.encode(readingAgeSeconds, forKey: .readingAgeSeconds)
            try c.encode(readingAge, forKey: .readingAge)
            try c.encode(stale, forKey: .stale)
            try c.encode(note, forKey: .note)
            try c.encode(windows, forKey: .windows)
        }
    }

    var schemaVersion: Int
    var generatedAt: String
    var app: App
    var verdict: Verdict
    var roomNow: Room?
    var lanes: [Lane]

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(generatedAt, forKey: .generatedAt)
        try c.encode(app, forKey: .app)
        try c.encode(verdict, forKey: .verdict)
        try c.encode(roomNow, forKey: .roomNow)
        try c.encode(lanes, forKey: .lanes)
    }

    /// True when at least one lane carries a current percentage.
    var hasAnyReading: Bool { lanes.contains { $0.usedPercent != nil } }

    func lane(_ provider: String) -> Lane? {
        lanes.first { $0.provider == provider.lowercased() }
    }
}

// MARK: - Pace (pure twin of UsageView.lanePace)

/// Pure equivalent of `lanePace` in UsageView.swift (a UI file), with the
/// same thresholds: spent ≥ 99.5, almost spent ≥ 90, a full/tight 5-hour
/// window (≥ 95) outranks weekly pace, running hot when used% − elapsed% > 15,
/// room when < −15, linear empty-time forecast. Kept in step by
/// AgentSummaryTests; if lanePace's thresholds change, change these too.
enum AgentPace {
    static let spentAt = 99.5
    static let almostSpentAt = 90.0
    static let sessionTightAt = 95.0
    static let paceBand = 15.0
    /// Panel rule: a window reading over 30 minutes old shows its age.
    static let staleAfter: TimeInterval = 30 * 60

    struct Evaluation: Equatable {
        /// The panel's words ("ON PACE", "RUNNING HOT", "5H TIGHT"…).
        var status: String
        /// on_pace | running_hot | room | almost_spent | spent | unknown
        var pace: String
        /// Percent the panel would compare against pace (lanePace's `used`).
        var used: Double?
        var elapsed: Double?
        /// 5h | week | day — the window `used` describes; nil without one.
        var window: String?
        var resetAt: Date?
        var forecastEmptyAt: Date?
        /// A carried-over percentage from before the window expired.
        var historical = false
        /// The HUD's own inference (idle lane 0%), not a provider number.
        var derived = false
        /// The window's reading is older than `staleAfter`.
        var stale = false
        /// When the lane is headlined by its full/tight 5-hour window.
        var sessionOverride: (used: Double, resetAt: Date?)? = nil

        static func == (a: Evaluation, b: Evaluation) -> Bool {
            a.status == b.status && a.pace == b.pace && a.used == b.used && a.elapsed == b.elapsed
                && a.window == b.window && a.resetAt == b.resetAt && a.forecastEmptyAt == b.forecastEmptyAt
                && a.historical == b.historical && a.derived == b.derived && a.stale == b.stale
                && a.sessionOverride?.used == b.sessionOverride?.used
                && a.sessionOverride?.resetAt == b.sessionOverride?.resetAt
        }
    }

    static func evaluate(_ snapshot: UsageSnapshot?, now: Date = Date()) -> Evaluation {
        guard let snap = snapshot else {
            return Evaluation(status: "NO DATA", pace: "unknown")
        }
        let provider = snap.provider.lowercased()

        var window = snap.week
        let geminiDaily = provider == "gemini" && snap.week?.label?.lowercased().contains("week") != true
        var tag = geminiDaily ? "day" : "week"
        var duration: TimeInterval = geminiDaily ? 24 * 3600 : 7 * 24 * 3600
        if window?.usedPct == nil, snap.currentSession?.usedPct != nil {
            window = snap.currentSession
            tag = "5h"
            duration = 5 * 3600
        }

        guard let w = window, let used = w.usedPct else {
            if let w = window, w.isExpired {
                return Evaluation(status: "IDLE", pace: "unknown", used: w.displayUsedPct, window: tag, historical: true)
            }
            if let w = window, w.isUnknown {
                return Evaluation(status: "WAIT", pace: "unknown", window: tag)
            }
            if let eventDate = UsageInsights.parseDate(snap.eventAt ?? snap.updatedAt),
               now.timeIntervalSince(eventDate) > 3600 {
                return Evaluation(status: "IDLE", pace: "unknown", used: 0, window: tag, derived: true)
            }
            return Evaluation(status: "WAIT", pace: "unknown", window: tag)
        }

        let reset = UsageInsights.resetDate(for: w, now: now)
        if let reset, reset <= now {
            return Evaluation(status: "RESET PASSED", pace: "unknown", window: tag)
        }

        var elapsed: Double?
        if let reset {
            let remaining = reset.timeIntervalSince(now)
            elapsed = max(0, min(100, (1 - remaining / duration) * 100))
        }

        // Same freshness truth as the panel (LaneFreshness), so an agent and
        // the user never disagree about whether a reading is old.
        let stale = UsageInsights.laneFreshness(for: snap, now: now).isOld

        var result = Evaluation(status: "PACE UNKNOWN", pace: "unknown", used: used, elapsed: elapsed,
                                window: tag, resetAt: reset, stale: stale)
        if used >= spentAt {
            result.status = "SPENT"
            result.pace = "spent"
        } else if used >= almostSpentAt {
            result.status = "ALMOST SPENT"
            result.pace = "almost_spent"
        } else if tag != "5h", let s = snap.currentSession, let su = s.usedPct, su >= sessionTightAt,
                  UsageInsights.resetDate(resetAt: s.resetAt, resetLabel: s.resetLabel, now: now).map({ $0 > now }) ?? true {
            // "Can I use this lane right now?" outranks weekly pace.
            result.status = su >= spentAt ? "5H FULL" : "5H TIGHT"
            result.pace = su >= spentAt ? "spent" : "almost_spent"
            result.sessionOverride = (su, UsageInsights.resetDate(resetAt: s.resetAt, resetLabel: s.resetLabel, now: now))
        } else if let reset, reset.timeIntervalSince(now) <= min(45 * 60, duration * 0.05) {
            // Window endgame: the imminent reset is the actionable fact. The
            // enum still reports pace so an agent can tell room from no room.
            result.status = "RESETS SOON"
            result.pace = elapsed.map { paceWord(used: used, elapsed: $0) } ?? "unknown"
        } else if let e = elapsed {
            result.pace = paceWord(used: used, elapsed: e)
            switch result.pace {
            case "running_hot":
                result.status = "RUNNING HOT"
                result.forecastEmptyAt = forecastEmpty(used: used, elapsed: e, duration: duration, now: now)
            case "room":
                result.status = "ROOM TO BURN"
            default:
                result.status = "ON PACE"
            }
        }
        return result
    }

    static func paceWord(used: Double, elapsed: Double) -> String {
        let delta = used - elapsed
        if delta > paceBand { return "running_hot" }
        if delta < -paceBand { return "room" }
        return "on_pace"
    }

    /// Linear projection: at the current burn rate, when does the window hit 100%?
    static func forecastEmpty(used: Double, elapsed: Double, duration: TimeInterval, now: Date) -> Date? {
        let elapsedSecs = duration * elapsed / 100
        guard used > 0, elapsedSecs > duration * 0.02 else { return nil }
        let rate = used / elapsedSecs
        return now.addingTimeInterval((100 - used) / rate)
    }

    /// Pace for a single window, independent of the lane headline.
    static func windowPace(_ w: UsageSnapshot.WindowMetric, duration: TimeInterval, now: Date) -> (pace: String, state: String, used: Double?, resetAt: Date?) {
        let reset = UsageInsights.resetDate(for: w, now: now)
        if w.isExpired { return ("unknown", "expired", nil, reset) }
        if w.isUnknown { return ("unknown", "unknown", nil, reset) }
        guard let used = w.usedPct else { return ("unknown", "unknown", nil, reset) }
        if let reset, reset <= now { return ("unknown", "reset_passed", nil, reset) }
        if used >= spentAt { return ("spent", "live", used, reset) }
        if used >= almostSpentAt { return ("almost_spent", "live", used, reset) }
        guard let reset else { return ("unknown", "live", used, nil) }
        let elapsed = max(0, min(100, (1 - reset.timeIntervalSince(now) / duration) * 100))
        return (paceWord(used: used, elapsed: elapsed), "live", used, reset)
    }
}

// MARK: - Budget mode (pure twin of BudgetEvaluator.computeMode)

/// The weekly/session thresholds BudgetEvaluator grades a lane with. The
/// defaults equal BudgetEvaluator's built-in policy; `AgentSummaryLoader`
/// reads an owner's `token-budget.json` overrides read-only. Computing the
/// mode here (instead of reading token-budget-state files) keeps the CLI
/// correct when the app is not running and never writes state.
struct AgentBudgetThresholds: Equatable, Sendable {
    var weeklyGreenMax = 60.0
    var weeklyYellowMax = 80.0
    var weeklyOrangeMax = 90.0
    var weeklyRedMax = 99.0
    var weeklyFreezeAt = 100.0
    var sessionYellowMax = 60.0
    var sessionOrangeMax = 80.0
    var sessionRedMax = 95.0

    static let standard = AgentBudgetThresholds()

    init() {}

    init(policy: [String: Any]) {
        let budgets = policy["budgets"] as? [String: Any] ?? [:]
        let w = budgets["weeklyPct"] as? [String: Any] ?? [:]
        let s = budgets["currentSessionPct"] as? [String: Any] ?? [:]
        weeklyGreenMax = Self.number(w["greenMax"]) ?? weeklyGreenMax
        weeklyYellowMax = Self.number(w["yellowMax"]) ?? weeklyYellowMax
        weeklyOrangeMax = Self.number(w["orangeMax"]) ?? weeklyOrangeMax
        weeklyRedMax = Self.number(w["redMax"]) ?? weeklyRedMax
        weeklyFreezeAt = Self.number(w["freezeAt"]) ?? weeklyFreezeAt
        sessionYellowMax = Self.number(s["yellowMax"]) ?? sessionYellowMax
        sessionOrangeMax = Self.number(s["orangeMax"]) ?? sessionOrangeMax
        sessionRedMax = Self.number(s["redMax"]) ?? sessionRedMax
    }

    /// green | yellow | orange | red | freeze | unknown — the worse of the
    /// weekly and 5-hour grades, exactly as BudgetEvaluator grades them.
    func mode(weekly: Double?, session: Double?) -> String {
        if weekly == nil && session == nil { return "unknown" }
        var weeklyMode = "green"
        if let weekly {
            if weekly >= weeklyFreezeAt || weekly > weeklyRedMax { weeklyMode = "freeze" }
            else if weekly > weeklyOrangeMax { weeklyMode = "red" }
            else if weekly > weeklyYellowMax { weeklyMode = "orange" }
            else if weekly > weeklyGreenMax { weeklyMode = "yellow" }
        }
        var sessionMode = "green"
        if let session {
            if session > sessionRedMax { sessionMode = "red" }
            else if session > sessionOrangeMax { sessionMode = "orange" }
            else if session > sessionYellowMax { sessionMode = "yellow" }
        }
        let rank: [String: Int] = ["green": 0, "yellow": 1, "orange": 2, "red": 3, "freeze": 4]
        return (rank[weeklyMode] ?? 0) >= (rank[sessionMode] ?? 0) ? weeklyMode : sessionMode
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }
}

// MARK: - Builder

extension AgentSummary {
    /// Presentation order the panel uses (UsageView.presentationSorted).
    static let presentationPriority = ["claude", "codex", "gemini", "grok", "local"]

    static func presentationSorted(_ providers: [String]) -> [String] {
        providers.enumerated().sorted { a, b in
            let pa = presentationPriority.firstIndex(of: a.element) ?? 99
            let pb = presentationPriority.firstIndex(of: b.element) ?? 99
            return pa == pb ? a.offset < b.offset : pa < pb
        }.map(\.element)
    }

    /// Build the summary from already-loaded snapshots. Pure: no file or
    /// network access, so tests drive it with fixture snapshots and a fixed
    /// clock.
    ///
    /// - Parameters:
    ///   - snapshots: in UsageStore order (the order ties are broken in).
    ///   - visibleProviders: the lanes the panel shows (connected + shown).
    static func build(
        snapshots: [UsageSnapshot],
        visibleProviders: [String],
        thresholds: AgentBudgetThresholds = .standard,
        appVersion: String = AppInfo.marketingVersion,
        now: Date = Date()
    ) -> AgentSummary {
        let order = presentationSorted(visibleProviders.map { $0.lowercased() })
        let visible = Set(order)
        let visibleSnapshots = snapshots.filter { visible.contains($0.provider.lowercased()) }

        var lanes: [Lane] = []
        var evaluations: [String: AgentPace.Evaluation] = [:]
        for provider in order {
            let snap = UsageInsights.snapshot(for: provider, in: visibleSnapshots)
            let eval = AgentPace.evaluate(snap, now: now)
            evaluations[provider] = eval
            lanes.append(lane(provider: provider, snapshot: snap, eval: eval, snapshots: visibleSnapshots, now: now))
        }

        // Lanes HeroVerdict may offer as "has room": the panel's rule.
        let heroLanes: [(provider: String, lane: HeroVerdict.Lane)] = order.compactMap { provider in
            guard provider != "local",
                  !UsageInsights.isManualObservationLane(provider, snapshots: visibleSnapshots),
                  let snap = UsageInsights.snapshot(for: provider, in: visibleSnapshots),
                  let eval = evaluations[provider] else { return nil }
            return (provider, HeroVerdict.Lane(
                name: UsageInsights.label(for: provider),
                used: eval.historical || eval.derived ? nil : eval.used,
                // The panel's word for a spent lane, so HeroVerdict's
                // blocked set matches exactly.
                paceStatus: eval.status == "SPENT" ? "✓ SPENT" : eval.status,
                fresh: !eval.stale && UsageInsights.isReadingFresh(snap, within: 30 * 60, now: now)
            ))
        }

        let primary = primarySnapshot(visibleSnapshots: visibleSnapshots, visible: visible)
        let verdict = makeVerdict(primary: primary, evaluations: evaluations, heroLanes: heroLanes.map(\.lane),
                                  lanes: lanes, thresholds: thresholds, now: now)
        let roomNow = mostRoom(heroLanes: heroLanes, lanes: lanes)

        return AgentSummary(
            schemaVersion: currentSchemaVersion,
            generatedAt: isoString(now),
            app: App(name: AppInfo.productName, version: appVersion),
            verdict: verdict,
            roomNow: roomNow,
            lanes: lanes
        )
    }

    /// Mirrors UsageView.primaryBudgetSnapshot: Claude when shown and it has
    /// a window, else the lane with the tightest window, else Claude or the
    /// first visible snapshot.
    static func primarySnapshot(visibleSnapshots: [UsageSnapshot], visible: Set<String>) -> UsageSnapshot? {
        let claude = visible.contains("claude") ? UsageInsights.snapshot(for: "claude", in: visibleSnapshots) : nil
        if let claude, claude.week != nil || claude.currentSession != nil { return claude }
        var worst: (provider: String, used: Double)?
        for snap in visibleSnapshots {
            let pid = snap.provider.lowercased()
            if let used = snap.currentSession?.usedPct, worst == nil || used > worst!.used { worst = (pid, used) }
            if let used = snap.week?.usedPct, worst == nil || used > worst!.used { worst = (pid, used) }
        }
        if let worst { return UsageInsights.snapshot(for: worst.provider, in: visibleSnapshots) }
        return claude ?? visibleSnapshots.first
    }

    static func agentMode(_ heroMode: String) -> String {
        switch heroMode.lowercased() {
        case "green": return "GO"
        case "yellow", "orange": return "WATCH"
        case "red", "freeze": return "STOP"
        default: return "CHECK"
        }
    }

    private static func makeVerdict(
        primary: UsageSnapshot?,
        evaluations: [String: AgentPace.Evaluation],
        heroLanes: [HeroVerdict.Lane],
        lanes: [Lane],
        thresholds: AgentBudgetThresholds,
        now: Date
    ) -> Verdict {
        guard let snap = primary else {
            let hero = HeroVerdict.resolve(mode: "unknown", laneName: nil, readingFresh: false, paceStatus: nil)
            return Verdict(mode: agentMode(hero.mode), lane: nil, laneName: nil,
                           sentence: "\(hero.tagline). Usage HUD has no readings yet; open Usage HUD and click Set up.")
        }
        let provider = snap.provider.lowercased()
        let name = UsageInsights.label(for: provider)
        let eval = evaluations[provider] ?? AgentPace.evaluate(snap, now: now)
        let raw = thresholds.mode(weekly: snap.week?.usedPct, session: snap.currentSession?.usedPct)
        let hero = HeroVerdict.resolve(
            mode: raw,
            laneName: name,
            readingFresh: UsageInsights.isReadingFresh(snap, within: 15 * 60, now: now),
            paceStatus: eval.status
        )
        var sentence = hero.tagline + "."
        if hero.mode == "check", let age = lanes.first(where: { $0.provider == provider })?.readingAge {
            if provider == "claude", snap.officialUsageStatus?.status?.lowercased() == "rate_limited" {
                sentence += " The last \(name) reading is \(age) old; a provider cooldown is in effect, and Usage HUD retries automatically."
            } else {
                sentence += " The last \(name) reading is \(age) old; open Usage HUD to refresh it."
            }
        }
        if let alternative = HeroVerdict.alternative(mode: hero.mode, primary: name, lanes: heroLanes) {
            sentence += " " + alternative.replacingOccurrences(of: " · ", with: ", ") + "."
        }
        return Verdict(mode: agentMode(hero.mode), lane: provider, laneName: name, sentence: sentence)
    }

    /// HeroVerdict.alternative's filter without its "only when pressed" and
    /// "not the primary" gates: the current lane with the most room.
    private static func mostRoom(heroLanes: [(provider: String, lane: HeroVerdict.Lane)], lanes: [Lane]) -> Room? {
        let blocked = HeroVerdict.pressingStatuses.union(["✓ SPENT", "SPENT", "NO DATA", "WAIT", "RESET PASSED"])
        let best = heroLanes
            .filter { $0.lane.fresh && !blocked.contains($0.lane.paceStatus) }
            .compactMap { item in item.lane.used.map { (item.provider, $0) } }
            .filter { $0.1 < 60 }
            .min { $0.1 < $1.1 }
        guard let (provider, _) = best, let lane = lanes.first(where: { $0.provider == provider }),
              let used = lane.usedPercent else { return nil }
        return Room(lane: provider, laneName: lane.name, window: lane.window, usedPercent: used,
                    pace: lane.pace, resetsAt: lane.resetsAt, resetsIn: lane.resetsIn)
    }

    private static func lane(provider: String, snapshot snap: UsageSnapshot?, eval: AgentPace.Evaluation,
                             snapshots: [UsageSnapshot], now: Date) -> Lane {
        let name = UsageInsights.label(for: provider)
        let trust = UsageInsights.displayTrust(for: snap, historical: eval.historical, derived: eval.derived, now: now)

        let readingDate: Date? = {
            guard let snap else { return nil }
            return UsageInsights.hasWindowData(snap) ? UsageInsights.windowEventDate(snap) : UsageInsights.capturedDate(snap)
        }()
        let ageSeconds = readingDate.map { max(0, Int(now.timeIntervalSince($0).rounded())) }

        // Headline: a full/tight 5-hour window replaces the weekly numbers,
        // because that is the window deciding whether the lane works now.
        var window = eval.window
        var used: Double? = eval.historical || eval.derived ? nil : eval.used
        var resetAt = eval.resetAt
        if let override = eval.sessionOverride {
            window = "5h"
            used = override.used
            resetAt = override.resetAt
        }

        return Lane(
            provider: provider,
            name: name,
            window: snap == nil ? nil : window,
            usedPercent: used.map(round1),
            resetsAt: resetAt.map(isoString),
            resetsIn: resetAt.flatMap { durationText(until: $0, now: now) },
            pace: eval.pace,
            status: eval.status,
            forecastEmptyAt: eval.forecastEmptyAt.map(isoString),
            confidence: snap == nil ? "unknown" : confidenceWord(trust.level),
            source: snap.map { safeSource(UsageInsights.sourceQuality($0)) } ?? "none",
            readingAgeSeconds: ageSeconds,
            readingAge: ageSeconds.map { durationText(seconds: TimeInterval($0)) },
            stale: snap.map { UsageInsights.laneFreshness(for: $0, now: now).isOld } ?? true,
            note: note(provider: provider, snapshot: snap, eval: eval, snapshots: snapshots),
            windows: snap.map { windows(for: $0, now: now) } ?? []
        )
    }

    private static func windows(for snap: UsageSnapshot, now: Date) -> [Window] {
        var out: [Window] = []
        let geminiDaily = snap.provider.lowercased() == "gemini" && snap.week?.label?.lowercased().contains("week") != true
        func add(_ metric: UsageSnapshot.WindowMetric?, window: String, scope: String?, duration: TimeInterval) {
            guard let metric else { return }
            let p = AgentPace.windowPace(metric, duration: duration, now: now)
            out.append(Window(
                window: window,
                scope: scope,
                usedPercent: p.used.map(round1),
                resetsAt: p.state == "live" ? p.resetAt.map(isoString) : nil,
                resetsIn: p.state == "live" ? p.resetAt.flatMap { durationText(until: $0, now: now) } : nil,
                pace: p.pace,
                state: p.state
            ))
        }
        add(snap.currentSession, window: "5h", scope: nil, duration: 5 * 3600)
        add(snap.week, window: geminiDaily ? "day" : "week", scope: nil, duration: geminiDaily ? 24 * 3600 : 7 * 24 * 3600)
        add(snap.weekFable, window: "week", scope: "Fable", duration: 7 * 24 * 3600)
        return out
    }

    private static func note(provider: String, snapshot snap: UsageSnapshot?, eval: AgentPace.Evaluation,
                             snapshots: [UsageSnapshot]) -> String? {
        if provider == "local" {
            return "Local models have no plan limit; this lane counts tokens only."
        }
        let manual = UsageInsights.isManualObservationLane(provider, snapshots: snapshots)
        switch eval.status {
        case "NO DATA":
            return "No reading has landed for this lane yet."
        case "IDLE":
            return eval.historical
                ? "The window reset since the last reading and nothing has run since."
                : "Nothing has run since the last window reset, so the window is likely clear."
        case "WAIT":
            return manual
                ? "This lane is read by hand; the last reading has expired."
                : "The provider has not reported a current window yet."
        case "RESET PASSED":
            return "The window has reset; waiting for a new reading."
        case "5H FULL":
            return "The 5-hour window is full; the weekly window still has room."
        case "5H TIGHT":
            return "The 5-hour window is nearly full; the weekly window still has room."
        case "RUNNING HOT":
            return "At this pace the window runs out before it resets."
        case "RESETS SOON":
            return "The window resets soon."
        default:
            return manual ? "This lane is read by hand." : nil
        }
    }

    static func confidenceWord(_ level: String) -> String {
        switch level {
        case "official": return "official"
        case "high": return "measured"
        case "medium", "manual": return "estimated"
        default: return "unknown"
        }
    }

    /// Source labels come from a fixed mapping, but an unknown source falls
    /// back to the writer's text; never let a path through.
    static func safeSource(_ label: String) -> String {
        if label.contains("/") || label.contains("~") || label.contains("\\") { return "local snapshot" }
        return label
    }

    static func round1(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (value * 10).rounded() / 10
    }

    static func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// "35m", "2h 10m", "4d 2h"; nil once the date has passed.
    static func durationText(until date: Date, now: Date) -> String? {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        return durationText(seconds: seconds)
    }

    static func durationText(seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(max(total, 0))s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60, mins = minutes % 60
        if hours < 24 { return mins == 0 ? "\(hours)h" : "\(hours)h \(mins)m" }
        let days = hours / 24, hrs = hours % 24
        return hrs == 0 ? "\(days)d" : "\(days)d \(hrs)h"
    }
}

// MARK: - Room advice (which_plan_has_room / `room`)

struct AgentRoomAdvice: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var generatedAt: String
    var verdict: AgentSummary.Verdict
    var roomNow: AgentSummary.Room?
    var advice: String
    /// Lanes with a fresh reading that are not spent, least used first.
    var usable: [AgentSummary.Room]

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(generatedAt, forKey: .generatedAt)
        try c.encode(verdict, forKey: .verdict)
        try c.encode(roomNow, forKey: .roomNow)
        try c.encode(advice, forKey: .advice)
        try c.encode(usable, forKey: .usable)
    }

    init(summary: AgentSummary) {
        schemaVersion = summary.schemaVersion
        generatedAt = summary.generatedAt
        verdict = summary.verdict
        roomNow = summary.roomNow
        usable = summary.lanes
            .filter { !$0.stale && $0.usedPercent != nil && !["spent", "almost_spent", "unknown"].contains($0.pace) && $0.provider != "local" }
            .sorted { ($0.usedPercent ?? 100) < ($1.usedPercent ?? 100) }
            .map { AgentSummary.Room(lane: $0.provider, laneName: $0.name, window: $0.window, usedPercent: $0.usedPercent ?? 0,
                                      pace: $0.pace, resetsAt: $0.resetsAt, resetsIn: $0.resetsIn) }
        advice = Self.advice(summary: summary)
    }

    static func describe(_ room: AgentSummary.Room) -> String {
        var parts = ["\(formatPercent(room.usedPercent)) of its \(windowWords(room.window)) used", paceWords(room.pace)]
        if let resetsIn = room.resetsIn { parts.append("resets in \(resetsIn)") }
        return parts.joined(separator: ", ")
    }

    static func advice(summary: AgentSummary) -> String {
        let verdict = summary.verdict
        if let room = summary.roomNow {
            if verdict.mode == "GO" {
                if verdict.lane == room.lane {
                    return "\(room.laneName) is clear to build and has the most room: \(describe(room))."
                }
                return "\(verdict.sentence) \(room.laneName) has the most room: \(describe(room))."
            }
            // The verdict sentence may already name a lane with room; keep
            // only its headline so the advice names the lane once.
            let headline = verdict.sentence.components(separatedBy: ". ").first.map { $0.hasSuffix(".") ? $0 : $0 + "." }
                ?? verdict.sentence
            return "\(headline) Move long or parallel work to \(room.laneName): \(describe(room))."
        }
        guard summary.hasAnyReading else {
            return "Usage HUD has no readings yet. Ask the user to open Usage HUD and click Set up."
        }
        let fresh = summary.lanes.filter { !$0.stale && $0.usedPercent != nil }
        if fresh.isEmpty {
            let newest = summary.lanes.compactMap(\.readingAgeSeconds).min()
            let age = newest.map { " The newest is \(AgentSummary.durationText(seconds: TimeInterval($0))) old." } ?? ""
            return "No plan has a fresh reading, so Usage HUD cannot say which has room.\(age) Ask the user to open Usage HUD so it refreshes."
        }
        var text = "No plan clearly has room right now. \(verdict.sentence)"
        if let soonest = summary.lanes
            .filter({ $0.provider != "local" && $0.resetsAt != nil && $0.resetsIn != nil })
            .min(by: { ($0.resetsAt ?? "") < ($1.resetsAt ?? "") }),
           let resetsIn = soonest.resetsIn {
            text += " Keep work small; \(soonest.name) resets in \(resetsIn)."
        } else {
            text += " Keep work small until a window resets."
        }
        return text
    }

    static func windowWords(_ window: String?) -> String {
        switch window {
        case "5h": return "5-hour window"
        case "day": return "daily quota"
        case "week": return "week"
        default: return "limit"
        }
    }

    static func paceWords(_ pace: String) -> String {
        switch pace {
        case "on_pace": return "on pace"
        case "running_hot": return "running hot"
        case "room": return "room to spare"
        case "almost_spent": return "almost spent"
        case "spent": return "spent"
        default: return "pace unknown"
        }
    }

    static func formatPercent(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value))%" : String(format: "%.1f%%", value)
    }
}

// MARK: - Loader (read-only)

/// Reads the same state files the app reads, without writing anything:
/// no budget-state persistence, no README badge sync, no preferences
/// initialization. Works when the app is not running; every lane reports
/// how old its reading is.
enum AgentSummaryLoader {
    static func load(now: Date = Date()) -> AgentSummary {
        let result = UsageStore.loadSnapshotResult()
        let visible = UsageInsights.visibleProviderOrder(snapshots: result.snapshots)
        return AgentSummary.build(
            snapshots: result.snapshots,
            visibleProviders: visible,
            thresholds: thresholds(),
            appVersion: AppInfo.resolvedMarketingVersion,
            now: now
        )
    }

    static func thresholds() -> AgentBudgetThresholds {
        for url in UsagePaths.policyCandidates {
            guard let data = try? Data(contentsOf: url),
                  let policy = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            return AgentBudgetThresholds(policy: policy)
        }
        return .standard
    }
}
