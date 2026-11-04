import Foundation

struct SourceFreshness {
    let state: String
    let label: String
    let detail: String
    let rank: Int

    var isStale: Bool { rank >= 3 }
}

struct CreditPoolState: Identifiable {
    let id: String
    let displayName: String
    let remainingCredits: Double?
    let startingCredits: Double?
    let creditUSDValue: Double?
    let creditsPerUSD: Double?
    let status: String?
    let lastVerified: String?
    let expiry: String?
    let tracking: String?
    let guardrail: String?

    var remainingPercent: Double? {
        guard let remainingCredits, let startingCredits, startingCredits > 0 else { return nil }
        return remainingCredits / startingCredits * 100
    }

    var estimatedUSDRemaining: Double? {
        guard let remainingCredits, let creditsPerUSD, creditsPerUSD > 0 else { return nil }
        return remainingCredits / creditsPerUSD
    }
}

struct DailyRoomInfo: Equatable {
    let headroomPct: Double
    let spendablePct: Double?
    /// Whole days to reset, rounded up, for display copy like "3d to reset".
    let daysToReset: Int?
    /// The exact (fractional) days to reset used to compute `spendablePct`,
    /// so a reset 30 hours out divides room by 1.25 days, not 2 whole days.
    let exactDaysToReset: Double?
    let resetLabel: String?
    let resetKnown: Bool
    let usesFullHeadroom: Bool
}

enum UsageInsights {
    static let overviewTab = "overview"
    static let providerOrder = UsageStore.providers
    static var tabOrder: [String] { [overviewTab] + providerOrder }

    /// Lanes whose snapshot declares a manual/UI observation source kind
    /// rather than an official pull. A stale or absent reading here must never
    /// drive the header status chip or the manual-refresh footer, both of
    /// which are meant to reflect the official, always-on lanes.
    static func isManualObservationLane(_ provider: String, snapshots: [UsageSnapshot] = []) -> Bool {
        let id = provider.lowercased()
        guard let snap = snapshot(for: id, in: snapshots) else { return false }
        let kind = (snap.sourceKind ?? "").lowercased()
        return kind.contains("observation") || kind.contains("manual")
    }

    static func visibleProviderOrder(
        snapshots _: [UsageSnapshot],
        budgets _: [String: BudgetState] = [:],
        selection: ProviderSelection = ProviderPreferences.selection()
    ) -> [String] {
        // Show every connected+shown customer lane, even with no snapshot, so a
        // first launch can explain what to do instead of looking empty or zeroed.
        return providerOrder.filter { selection.includes($0) }
    }

    static func tabOrder(snapshots: [UsageSnapshot], budgets: [String: BudgetState] = [:]) -> [String] {
        [overviewTab] + visibleProviderOrder(snapshots: snapshots, budgets: budgets)
    }

    static func label(for id: String) -> String {
        switch id {
        case overviewTab: return "All"
        default: return ProviderCatalog.definition(for: id)?.name ?? id.capitalized
        }
    }

    static func shortLabel(for id: String) -> String {
        switch id {
        default: return ProviderCatalog.definition(for: id)?.shortName ?? String(label(for: id).prefix(2)).uppercased()
        }
    }

    static func snapshot(for provider: String, in snapshots: [UsageSnapshot]) -> UsageSnapshot? {
        snapshots.first { $0.provider.lowercased() == provider.lowercased() }
    }

    static func primaryPercent(_ snapshot: UsageSnapshot?) -> Double? {
        snapshot?.week?.usedPct ?? snapshot?.currentSession?.usedPct
    }

    static func contextTurnUsagePercent(_ session: UsageSnapshot.SessionMetrics) -> Double? {
        guard let lastTotal = session.lastTotal,
              let window = session.contextWindow,
              lastTotal > 0,
              window > 0
        else { return nil }
        return Double(lastTotal) / Double(window) * 100
    }

    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let normalized = normalizeISO8601(value)
        return fractionalDateFormatter.date(from: normalized)
            ?? plainDateFormatter.date(from: normalized)
    }

    /// Apple's ISO8601DateFormatter wants exactly three fractional digits.
    /// Grok billing and session stamps often arrive with 6-digit microseconds
    /// and `+00:00` offsets.
    static func normalizeISO8601(_ value: String) -> String {
        guard let dot = value.firstIndex(of: ".") else { return value }
        let fractionStart = value.index(after: dot)
        var index = fractionStart
        while index < value.endIndex, value[index].isNumber {
            index = value.index(after: index)
        }
        let digits = value[fractionStart..<index]
        guard !digits.isEmpty, digits.count != 3 else { return value }
        let trimmed = String((digits + "000").prefix(3))
        return String(value[value.startIndex..<fractionStart]) + trimmed + String(value[index...])
    }

    static func resetDate(
        for window: UsageSnapshot.WindowMetric,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        resetDate(resetAt: window.resetAt, resetLabel: window.resetLabel, now: now, calendar: calendar)
    }

    static func resetDate(
        resetAt: String?,
        resetLabel: String?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        if let iso = parseDate(resetAt) { return iso }
        guard let resetLabel else { return nil }
        return parseResetLabel(resetLabel, now: now, calendar: calendar)
    }

    static func dailyRoom(
        for snapshot: UsageSnapshot,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> DailyRoomInfo? {
        guard let week = snapshot.week, let used = week.usedPct else { return nil }
        let headroom = max(0, 100 - used)
        guard let resetAt = resetDate(for: week, now: now, calendar: calendar), resetAt > now else {
            return DailyRoomInfo(
                headroomPct: headroom,
                spendablePct: nil,
                daysToReset: nil,
                exactDaysToReset: nil,
                resetLabel: week.resetLabel,
                resetKnown: false,
                usesFullHeadroom: false
            )
        }

        let hours = resetAt.timeIntervalSince(now) / 3_600
        if hours <= 24 {
            return DailyRoomInfo(
                headroomPct: headroom,
                spendablePct: headroom,
                daysToReset: 1,
                exactDaysToReset: max(hours / 24, 1.0 / 24),
                resetLabel: week.resetLabel,
                resetKnown: true,
                usesFullHeadroom: true
            )
        }

        // Even pace divides by the exact (fractional) days left, not whole
        // days rounded up, so a reset 30 hours out paces against 1.25 days,
        // not 2 whole days.
        let exactDays = hours / 24
        let wholeDays = max(1, Int(ceil(exactDays)))
        return DailyRoomInfo(
            headroomPct: headroom,
            spendablePct: headroom / exactDays,
            daysToReset: wholeDays,
            exactDaysToReset: exactDays,
            resetLabel: week.resetLabel,
            resetKnown: true,
            usesFullHeadroom: false
        )
    }

    static func ageText(for value: String?, now: Date = Date()) -> String {
        guard let date = parseDate(value) else { return "unknown age" }
        return ageText(since: date, now: now)
    }

    static func ageText(since date: Date, now: Date = Date()) -> String {
        let delta = Int(now.timeIntervalSince(date))
        if delta < 0 {
            let remaining = abs(delta)
            if remaining < 60 { return "in \(remaining)s" }
            if remaining < 3_600 { return "in \(remaining / 60)m" }
            if remaining < 86_400 { return "in \(remaining / 3_600)h" }
            return "in \(remaining / 86_400)d"
        }
        let elapsed = delta
        if elapsed < 2 { return "now" }
        if elapsed < 60 { return "\(elapsed)s ago" }
        if elapsed < 3_600 { return "\(elapsed / 60)m ago" }
        if elapsed < 86_400 { return "\(elapsed / 3_600)h ago" }
        return "\(elapsed / 86_400)d ago"
    }

    static func eventDate(_ snapshot: UsageSnapshot?) -> Date? {
        parseDate(snapshot?.eventAt ?? snapshot?.updatedAt)
    }

    static func capturedDate(_ snapshot: UsageSnapshot?) -> Date? {
        parseDate(snapshot?.capturedAt ?? snapshot?.updatedAt)
    }

    /// True when a snapshot's own reading (capturedAt/updatedAt) is under
    /// `window` old. A missing snapshot is never fresh. Used to gate a
    /// confident verdict (e.g. the "clear to build" hero) so it never
    /// asserts freshness the reading doesn't have.
    static func isReadingFresh(_ snapshot: UsageSnapshot?, within window: TimeInterval, now: Date = Date()) -> Bool {
        guard let date = capturedDate(snapshot) else { return false }
        return now.timeIntervalSince(date) <= window
    }

    static func hasWindowData(_ snapshot: UsageSnapshot?) -> Bool {
        guard let snapshot else { return false }
        return snapshot.week?.usedPct != nil || snapshot.currentSession?.usedPct != nil
    }

    static func sourceFreshness(for snapshot: UsageSnapshot?, now: Date = Date()) -> SourceFreshness {
        guard let snapshot else {
            return SourceFreshness(state: "missing", label: "Missing", detail: "No snapshot file", rank: 4)
        }
        guard let date = capturedDate(snapshot) else {
            return SourceFreshness(state: "unknown", label: "Unknown", detail: "No capturedAt/updatedAt", rank: 2)
        }

        return freshness(since: date, now: now, freshSeconds: 6 * 60 * 60, agingSeconds: 24 * 60 * 60)
    }

    static func windowFreshness(for snapshot: UsageSnapshot?, now: Date = Date()) -> SourceFreshness? {
        guard let snapshot, hasWindowData(snapshot) else { return nil }
        guard let date = windowEventDate(snapshot) else {
            return SourceFreshness(state: "unknown", label: "Unknown", detail: "No eventAt/updatedAt", rank: 2)
        }

        if snapshot.currentSession?.usedPct != nil {
            return freshness(since: date, now: now, freshSeconds: 2 * 60 * 60, agingSeconds: 5 * 60 * 60)
        }
        return freshness(since: date, now: now, freshSeconds: 6 * 60 * 60, agingSeconds: 24 * 60 * 60)
    }

    /// True when the 5h/week windows are live (rank 0: event within the last
    /// 15 minutes) per `windowFreshness`. A live tap already proves the
    /// pipeline is working, so the header can look past a failed official
    /// refetch while this holds — but only as a second check: in
    /// `headerHasHealthWarning` this bypass runs after `snapshot.health?.isWarning`,
    /// so a writer-reported health warning always wins over a live window
    /// here, never the other way around. The keepalive writer now reports
    /// health fresh whenever the tap event is under 15 minutes old, so the
    /// two rarely disagree in practice; this function only ends up deciding
    /// the header when health is absent or stale rather than an active
    /// warning. See `headerHasHealthWarning`.
    static func hasLiveWindow(for snapshot: UsageSnapshot?, now: Date = Date()) -> Bool {
        windowFreshness(for: snapshot, now: now)?.rank == 0
    }

    /// Age the official window off its own stamp when the writer set one.
    /// Snapshot `eventAt` is last local activity and can lag a live billing
    /// reading (Grok CLI/TUI: official 0–n% fetched now, last session 2d ago).
    static func windowEventDate(_ snapshot: UsageSnapshot?) -> Date? {
        let window = snapshot?.week ?? snapshot?.currentSession
        return parseDate(window?.eventAt)
            ?? parseDate(window?.capturedAt)
            ?? eventDate(snapshot)
    }

    static func freshness(for snapshot: UsageSnapshot?, now: Date = Date()) -> SourceFreshness {
        sourceFreshness(for: snapshot, now: now)
    }

    private static func freshness(since date: Date, now: Date, freshSeconds: TimeInterval, agingSeconds: TimeInterval) -> SourceFreshness {
        let elapsed = now.timeIntervalSince(date)
        if elapsed <= 15 * 60 {
            return SourceFreshness(state: "live", label: "Live", detail: ageText(since: date, now: now), rank: 0)
        }
        if elapsed <= freshSeconds {
            return SourceFreshness(state: "fresh", label: "Fresh", detail: ageText(since: date, now: now), rank: 1)
        }
        if elapsed <= agingSeconds {
            return SourceFreshness(state: "aging", label: "Aging", detail: ageText(since: date, now: now), rank: 2)
        }
        return SourceFreshness(state: "stale", label: "Stale", detail: ageText(since: date, now: now), rank: 3)
    }

    private static func parseResetLabel(_ raw: String, now: Date, calendar: Calendar) -> Date? {
        var label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }

        label = label.replacingOccurrences(of: ",", with: " ")
        label = label.replacingOccurrences(of: #"(?i)^resets?\s+"#, with: "", options: .regularExpression)
        label = label.replacingOccurrences(of: #"(?i)\bat\b"#, with: " ", options: .regularExpression)
        label = label.replacingOccurrences(of: #"^([A-Za-z]+)(\d)"#, with: "$1 $2", options: .regularExpression)
        label = label.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let compact = label.replacingOccurrences(of: " ", with: "").lowercased()
        if compact.count > 1, let unit = compact.last, unit == "h" || unit == "d" {
            let amountText = compact.dropLast()
            if let amount = Double(amountText) {
                return now.addingTimeInterval(amount * (unit == "h" ? 3_600 : 86_400))
            }
        }

        let year = calendar.component(.year, from: now)
        let monthFormats = [
            "yyyy MMM d h:mm a",
            "yyyy MMM d h a",
            "yyyy MMM d HH:mm",
            "yyyy MMM d H:mm",
            "yyyy MMM d H",
            "yyyy MMMM d h:mm a",
            "yyyy MMMM d h a",
            "yyyy MMMM d HH:mm",
            "yyyy MMMM d H:mm",
            "yyyy MMMM d H"
        ]
        if let parsed = parseResetCandidate("\(year) \(label)", formats: monthFormats, calendar: calendar) {
            if parsed < now.addingTimeInterval(-180 * 86_400),
               let nextYear = calendar.date(byAdding: .year, value: 1, to: parsed) {
                return nextYear
            }
            return parsed
        }

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let today = dayFormatter.string(from: now)
        let timeFormats = [
            "yyyy-MM-dd h:mm a",
            "yyyy-MM-dd h a",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd H:mm",
            "yyyy-MM-dd H"
        ]
        if let parsed = parseResetCandidate("\(today) \(label)", formats: timeFormats, calendar: calendar) {
            if parsed < now.addingTimeInterval(-6 * 3_600),
               let tomorrow = calendar.date(byAdding: .day, value: 1, to: parsed) {
                return tomorrow
            }
            return parsed
        }

        return nil
    }

    private static func parseResetCandidate(_ value: String, formats: [String], calendar: Calendar) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    static func eventDetail(_ snapshot: UsageSnapshot?, now: Date = Date()) -> String? {
        guard let checked = capturedDate(snapshot),
              let event = eventDate(snapshot),
              abs(checked.timeIntervalSince(event)) > 60
        else { return nil }
        return "event \(ageText(since: event, now: now))"
    }

    static func windowCoverage(_ snapshot: UsageSnapshot?) -> String {
        guard let snapshot else { return "missing" }
        switch (snapshot.week?.usedPct, snapshot.currentSession?.usedPct) {
        case (.some, .some): return "week + session"
        case (.some, .none): return "week only"
        case (.none, .some): return "session only"
        default:
            if snapshot.session != nil { return "driver only" }
            return "no windows"
        }
    }

    static func sourceQuality(_ snapshot: UsageSnapshot?) -> String {
        guard let snapshot else { return "missing" }
        if let sourceKind = snapshot.sourceKind, !sourceKind.isEmpty {
            switch sourceKind {
            case "official_api": return "official API"
            case "official_interactive": return "official panel"
            case "local_session_log": return "local session log"
            case "local_runtime_log": return "local runtime log"
            case "statusline_event": return "statusline event"
            case "manual": return "manual"
            default: return sourceKind.replacingOccurrences(of: "_", with: " ")
            }
        }
        let source = (snapshot.source ?? "").lowercased()
        if source.contains("token tracker") { return "token tracker" }
        if source.contains("official") { return "official panel" }
        if source.contains("statusline") { return "live statusline" }
        if source.contains("quota") { return "quota API" }
        if source.contains("writer") { return "writer snapshot" }
        if source.contains("sessions") { return "session fallback" }
        return snapshot.source?.isEmpty == false ? snapshot.source! : "snapshot"
    }

    static func confidence(_ snapshot: UsageSnapshot?) -> (level: String, label: String, detail: String, rank: Int) {
        guard let snapshot else {
            return ("missing", "Missing", "No source available.", 4)
        }
        var raw = (snapshot.confidence ?? inferredConfidence(snapshot)).lowercased()
        // The label must match the source line: a "high" reading that came
        // from the provider's own API or quota panel is the official number,
        // so it reads "official", never "measured" beside "official API".
        if raw == "high", isOfficialSourceKind(snapshot.sourceKind) { raw = "official" }
        switch raw {
        case "official", "very_high":
            return ("official", "Official", snapshot.confidenceNote ?? "The provider's own number for this limit.", 0)
        case "high":
            return ("high", "High", snapshot.confidenceNote ?? "Counted from the tool's own records on this Mac.", 1)
        case "medium", "estimated", "derived":
            return ("medium", "Estimated", snapshot.confidenceNote ?? "Worked out from local usage, not reported by the provider.", 2)
        case "manual":
            return ("manual", "Manual", snapshot.confidenceNote ?? "Read by hand. Check it before relying on it.", 3)
        default:
            return ("unknown", "Unknown", snapshot.confidenceNote ?? "The source didn't say how it got this number.", 3)
        }
    }

    /// Trust label for a lane as the *collapsed* panel shows it. Confidence
    /// answers "where did this number come from"; `isLive` answers "is it
    /// still true". The two must travel together: an official reading that
    /// stopped refreshing is no longer an official statement about right now,
    /// so `chipLabel` refuses to print a bare "Official" once `isLive` is
    /// false. See `laneTrust(for:historical:now:)`.
    struct LaneTrust: Equatable {
        let level: String
        let label: String
        let note: String
        let rank: Int
        let isLive: Bool
        let ageDetail: String?

        /// What the collapsed chip prints. "Unknown" is already an admission,
        /// so it never takes the "· old" suffix — "Unknown · old" says nothing
        /// the bare word didn't.
        var chipLabel: String {
            if level == "unknown" || level == "missing" { return label }
            return isLive ? label : "\(label) · old"
        }

        /// The word the panel prints for this source. "High" sat beside
        /// percentages and read as "high usage"; it means measured locally.
        var word: String {
            switch level {
            case "official": return "official"
            case "high": return "measured"
            case "medium": return "estimated"
            case "manual": return "manual"
            default: return label.lowercased()
            }
        }

        var isGap: Bool { level == "unknown" || level == "missing" }

        /// "official", "measured · old" — the row tag and the card header
        /// both print exactly this.
        var tagText: String { isGap || isLive ? word : "\(word) · old" }

        /// `ageDetail` is a short age ("3h"), so both sentences read cleanly.
        var help: String {
            var parts = ["\(word.prefix(1).uppercased() + word.dropFirst()): \(note)"]
            if let ageDetail {
                parts.append(isLive ? "Read \(ageDetail) ago." : "This reading is \(ageDetail) old and has not refreshed since.")
            }
            return parts.joined(separator: " ")
        }
    }

    /// Resolve a lane's displayed trust. `historical` is the caller's own
    /// knowledge that the percentage on screen was carried over from before
    /// the window expired (see `LanePace.historical`) — freshness alone can't
    /// see that, because the writer keeps checking in while the number stops
    /// meaning anything.
    static func laneTrust(for snapshot: UsageSnapshot?, historical: Bool = false, now: Date = Date()) -> LaneTrust {
        guard let snapshot else {
            return LaneTrust(level: "missing", label: "Unknown", note: "No reading has landed for this lane yet.",
                             rank: 4, isLive: false, ageDetail: nil)
        }
        let conf = confidence(snapshot)
        // Same clock as the header pill, the row note and the verdict (see
        // `laneFreshness`): a tag only says "old" when everything else does.
        let fresh = laneFreshness(for: snapshot, now: now)
        return LaneTrust(level: conf.level, label: conf.label, note: conf.detail, rank: conf.rank,
                         isLive: !historical && !fresh.isOld, ageDetail: fresh.ageShort)
    }

    /// The trust a lane's chip must show for the number actually on screen,
    /// which is not always the trust of its source. `derived` marks a value the
    /// HUD inferred rather than one the provider reported — the idle-lane 0% is
    /// the case that matters: nothing ran, so the window really is clear, but
    /// the provider never said "0%" and the chip must not claim it did.
    static func displayTrust(for snapshot: UsageSnapshot?, historical: Bool = false,
                             derived: Bool = false, now: Date = Date()) -> LaneTrust {
        let base = laneTrust(for: snapshot, historical: historical, now: now)
        guard derived, base.rank < 2 else { return base }
        return LaneTrust(level: "medium", label: "Estimated",
                         note: "The provider reported no usage for this period, so the panel reads the lane as idle.",
                         rank: 2, isLive: base.isLive, ageDetail: base.ageDetail)
    }

    /// One plain-English line for the header when something visible on the
    /// panel is not a live, trustworthy number. Returns nil when every
    /// connected lane is both current and official/high — the honest case
    /// stays silent rather than reassuring the reader for no reason.
    /// `excluding` drops lanes another line already speaks for (the verdict
    /// saying "Claude: reading is 3h old" needs no second sentence).
    static func trustCaveat(snapshots: [UsageSnapshot], budgets: [String: BudgetState] = [:],
                            excluding: Set<String> = [], now: Date = Date()) -> String? {
        var old: [String] = []
        var soft: [String] = []
        for provider in visibleProviderOrder(snapshots: snapshots, budgets: budgets) {
            // Manual lanes carry their own age on their row; they never warn the whole panel.
            guard !isManualObservationLane(provider, snapshots: snapshots) else { continue }
            guard !excluding.contains(provider) else { continue }
            guard let snap = snapshot(for: provider, in: snapshots) else { continue }
            let trust = laneTrust(for: snap, now: now)
            if !trust.isLive {
                old.append(label(for: provider))
            } else if trust.rank >= 2 {
                soft.append(label(for: provider))
            }
        }
        var parts: [String] = []
        if !old.isEmpty {
            parts.append(old.count == 1 ? "\(old[0])'s reading is old" : "\(joinNames(old)) readings are old")
        }
        if !soft.isEmpty {
            parts.append("\(joinNames(soft)) \(soft.count == 1 ? "is" : "are") an estimate, not an official number")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "; ") + "."
    }

    private static func joinNames(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    static func isOfficialSourceKind(_ kind: String?) -> Bool {
        (kind ?? "").lowercased().hasPrefix("official")
    }

    /// Where a lane's number came from, in words a buyer reads at a glance.
    static func plainSource(_ snapshot: UsageSnapshot?) -> String {
        guard let snapshot else { return "No reading yet" }
        switch (snapshot.sourceKind ?? "").lowercased() {
        case "official_api": return "Official usage API"
        case "official_interactive": return "Official usage panel"
        case "official_app_server": return "Official account limits"
        case "statusline_event": return "Claude Code status line"
        case "local_session_log": return "Session logs on this Mac"
        case "local_runtime_log": return "Ollama logs on this Mac"
        case "manual", "native_ui_observation": return "Read from the app"
        default:
            let quality = sourceQuality(snapshot)
            return quality.prefix(1).uppercased() + quality.dropFirst()
        }
    }

    /// Hover text for a detail card's source line: plain sentences, with the
    /// writer's own note last.
    static func sourceHelp(_ snapshot: UsageSnapshot?, now: Date = Date()) -> String {
        guard let snapshot else { return "No reading has landed for this lane yet." }
        var parts = ["Source: \(plainSource(snapshot))."]
        let fresh = laneFreshness(for: snapshot, now: now)
        switch fresh.state {
        case .live: parts.append("Read in the last 10 minutes.")
        case .recent: parts.append("Last \(fresh.label).")
        case .old: parts.append(fresh.age.map { "This reading is \(LaneFreshness.short($0)) old and has not refreshed since." } ?? "No update time on this reading.")
        }
        if let checked = capturedDate(snapshot), abs(checked.timeIntervalSince(readingDate(snapshot) ?? checked)) > 60 {
            parts.append("Last checked \(ageText(since: checked, now: now)).")
        }
        if let detail = fresh.issueDetail { parts.append(detail) }
        parts.append(confidence(snapshot).detail)
        return parts.joined(separator: " ")
    }

    private static func inferredConfidence(_ snapshot: UsageSnapshot) -> String {
        let source = (snapshot.source ?? "").lowercased()
        let sourceKind = (snapshot.sourceKind ?? "").lowercased()
        if sourceKind.contains("official") || source.contains("official") || source.contains("quota") { return "official" }
        if ["local_session_log", "local_runtime_log"].contains(sourceKind) || source.contains("session") || source.contains("statusline") { return "high" }
        if source.contains("token tracker") || source.contains("writer") { return "medium" }
        return "unknown"
    }

    static func sourceDetail(_ snapshot: UsageSnapshot?, now: Date = Date()) -> String {
        guard let snapshot else { return "No provider snapshot has landed yet." }
        let sourceFreshness = sourceFreshness(for: snapshot, now: now)
        let windowFreshness = windowFreshness(for: snapshot, now: now)
        let checked = capturedDate(snapshot).map { "checked \(ageText(since: $0, now: now))" }
        let sourceAge = windowFreshness.map { "rate limit \($0.detail)" } ?? "checked \(sourceFreshness.detail)"
        let event = hasWindowData(snapshot) ? nil : eventDetail(snapshot, now: now)
        return ([sourceQuality(snapshot), sourceAge, checked, event, windowCoverage(snapshot)] as [String?])
            .compactMap { $0 }
            .reduce(into: [String]()) { parts, item in
                if parts.last != item { parts.append(item) }
            }
            .joined(separator: " · ")
    }

    static func highestPressureSnapshot(_ snapshots: [UsageSnapshot]) -> UsageSnapshot? {
        snapshots.max {
            (primaryPercent($0) ?? -1) < (primaryPercent($1) ?? -1)
        }
    }

    static func worstBudget(_ budgets: [String: BudgetState]) -> BudgetState? {
        budgets.values.max { modeRank($0.mode) < modeRank($1.mode) }
    }

    static func modeRank(_ mode: String) -> Int {
        switch mode.lowercased() {
        case "unknown": return -1
        case "green": return 0
        case "yellow": return 1
        case "orange": return 2
        case "red": return 3
        case "freeze": return 4
        default: return -1
        }
    }

    static func staleSourceProviders(_ snapshots: [UsageSnapshot], now: Date = Date()) -> [String] {
        visibleProviderOrder(snapshots: snapshots).compactMap { provider in
            // A manual/observation lane never auto-refreshes, so its age
            // must not read as a broken pipeline.
            guard !isManualObservationLane(provider, snapshots: snapshots) else { return nil }
            // A lane with no snapshot yet is "not connected", not stale.
            guard let snap = snapshot(for: provider, in: snapshots) else { return nil }
            return sourceFreshness(for: snap, now: now).isStale ? label(for: provider) : nil
        }
    }

    static func staleWindowProviders(_ snapshots: [UsageSnapshot], now: Date = Date()) -> [String] {
        visibleProviderOrder(snapshots: snapshots).compactMap { provider in
            guard !isManualObservationLane(provider, snapshots: snapshots) else { return nil }
            let snap = snapshot(for: provider, in: snapshots)
            return windowFreshness(for: snap, now: now)?.isStale == true ? label(for: provider) : nil
        }
    }

    static func staleProviders(_ snapshots: [UsageSnapshot], now: Date = Date()) -> [String] {
        staleSourceProviders(snapshots, now: now)
    }

    static func topDriverAlerts(_ budgets: [String: BudgetState]) -> [BudgetDriverAlert] {
        budgets.values
            .flatMap(\.driverAlerts)
            .sorted {
                if modeRank($0.severity) == modeRank($1.severity) { return $0.percent > $1.percent }
                return modeRank($0.severity) > modeRank($1.severity)
            }
    }

    static func nextAction(snapshots: [UsageSnapshot], budgets: [String: BudgetState]) -> String {
        if let worst = worstBudget(budgets), modeRank(worst.mode) >= modeRank("red") {
            return "Stop new agent spend; handle only incidents, client blockers, and exact handoffs."
        }
        let staleSources = staleSourceProviders(snapshots)
        if !staleSources.isEmpty {
            return "Refresh stale sources: \(staleSources.joined(separator: ", "))."
        }
        let staleWindows = staleWindowProviders(snapshots)
        if !staleWindows.isEmpty {
            return "Official windows old: \(staleWindows.joined(separator: ", ")); tracker checks are still alive."
        }
        if let top = highestPressureSnapshot(snapshots), let pct = primaryPercent(top), pct >= 80 {
            return "Conserve \(label(for: top.provider)); use local shell, Gemini, or fresh short contexts."
        }
        let unknown = budgets
            .filter { $0.value.mode.lowercased() == "unknown" }
            .map { label(for: $0.key) }
            .sorted()
        if !unknown.isEmpty {
            return "Waiting for fresh official windows: \(unknown.joined(separator: ", "))."
        }
        if !topDriverAlerts(budgets).isEmpty {
            return "Trim the top driver before opening another long-running agent loop."
        }
        return "All lanes usable; keep assignments scoped and close loops."
    }
}

enum CreditPoolReader {
    static func load(for provider: String) -> CreditPoolState? {
        guard let policy = loadPolicy() else { return nil }
        return parse(provider: provider, policy: policy)
    }

    private static func loadPolicy() -> [String: Any]? {
        for url in UsagePaths.policyCandidates {
            guard let data = try? Data(contentsOf: url),
                  let policy = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            return policy
        }
        return nil
    }

    static func parse(provider: String, policy: [String: Any]) -> CreditPoolState? {
        let poolKey = (policy["providerCreditPools"] as? [String: Any])?[provider] as? String
        guard let poolKey,
              let pools = policy["creditPools"] as? [String: Any],
              let raw = pools[poolKey] as? [String: Any]
        else { return nil }

        return CreditPoolState(
            id: poolKey,
            displayName: raw["displayName"] as? String ?? poolKey,
            remainingCredits: number(raw["remainingCreditsManual"]),
            startingCredits: number(raw["startingCredits"]),
            creditUSDValue: number(raw["creditUSDValue"]),
            creditsPerUSD: number(raw["creditsPerUSD"]),
            status: raw["status"] as? String,
            lastVerified: raw["lastVerified"] as? String,
            expiry: raw["expiry"] as? String,
            tracking: raw["tracking"] as? String,
            guardrail: raw["guardrail"] as? String
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }
}
