import Foundation

enum UsageStore {
    static let providers = ProviderCatalog.ids

    static func loadSnapshotResult() -> UsageLoadResult {
        let decoder = JSONDecoder()
        let fm = FileManager.default
        var loaded: [UsageSnapshot] = []
        var errors: [String] = []

        let selection = ProviderPreferences.selection()
        for provider in providers where selection.connected.contains(provider) {
            if let path = newestExistingPath(for: provider, fileManager: fm) {
                do {
                    var snapshot = try cachedSnapshot(at: path, decoder: decoder).get()
                    snapshot.loadedFromPath = path.path
                    // The in-app reader's file carries its own status; the
                    // shared status file belongs to the LaunchAgent fetch.
                    if provider == "claude", path.lastPathComponent != UsagePaths.claudeNativeUsageFilename {
                        snapshot = mergeClaudeOfficialStatus(snapshot, decoder: decoder, fileManager: fm)
                    }
                    if provider == "gemini", let local = GeminiSessionReader.loadSnapshot() {
                        snapshot = mergeGeminiQuotaSnapshot(snapshot, withLocal: local)
                    }
                    loaded.append(dropExpiredWindows(snapshot))
                } catch {
                    errors.append("\(provider): \(path.lastPathComponent) \(error.localizedDescription)")
                }
            } else if !UsagePaths.isIsolatedStateDir, provider == "codex", let snapshot = CodexSessionReader.loadSnapshot() {
                loaded.append(dropExpiredWindows(snapshot))
            } else if !UsagePaths.isIsolatedStateDir, provider == "gemini", let snapshot = GeminiSessionReader.loadSnapshot() {
                loaded.append(dropExpiredWindows(snapshot))
            } else if !UsagePaths.isIsolatedStateDir, provider == "local", let snapshot = LocalModelUsageReader.loadSnapshot() {
                loaded.append(snapshot)
            }
        }

        return UsageLoadResult(
            snapshots: loaded.sorted { providerRank($0.provider) < providerRank($1.provider) },
            errors: errors
        )
    }

    /// Decoded provider JSON keyed by path + mtime + size, so an unchanged
    /// file is not re-read or re-decoded on every refresh tick. Time-based
    /// cleanup (`dropExpiredWindows`) still runs on every load.
    private static let snapshotCache = FileSignatureCache<Result<UsageSnapshot, Error>>()
    private static let healthCache = FileSignatureCache<UsageSnapshot.ProviderHealth?>()

    private static func cachedSnapshot(at path: URL, decoder: JSONDecoder) -> Result<UsageSnapshot, Error> {
        snapshotCache.value(for: path) { url in
            Result {
                try decoder.decode(UsageSnapshot.self, from: Data(contentsOf: url))
            }
        }
    }

    private static func providerRank(_ provider: String) -> Int {
        providers.firstIndex(of: provider.lowercased()) ?? providers.count
    }

    private static func newestExistingPath(for provider: String, fileManager fm: FileManager) -> URL? {
        let existing = candidates(for: provider).filter { fm.fileExists(atPath: $0.path) }
        if provider == "claude",
           let native = existing.first(where: { $0.lastPathComponent == UsagePaths.claudeNativeUsageFilename }),
           let status = loadProviderHealth(filenames: ["claude-official-status.json"], decoder: JSONDecoder(), fileManager: fm),
           let bgStatus = status.status?.lowercased(), ["keychain_locked", "no_credential"].contains(bgStatus),
           let nativeSnap = try? cachedSnapshot(at: native, decoder: JSONDecoder()).get(),
           let nativeStatus = nativeSnap.officialUsageStatus?.status?.lowercased() {
            let sharedSnap = existing.first { $0.lastPathComponent != UsagePaths.claudeNativeUsageFilename }
                .flatMap { try? cachedSnapshot(at: $0, decoder: JSONDecoder()).get() }
            if nativeStatus == "ok", (UsageInsights.readingDate(nativeSnap) ?? .distantPast) > (sharedSnap.flatMap(UsageInsights.readingDate) ?? .distantPast) {
                return native
            }
            if bgStatus == "keychain_locked", nativeStatus != "keychain_locked",
               (UsageInsights.parseDate(nativeSnap.officialUsageStatus?.updatedAt) ?? .distantPast) >= (UsageInsights.parseDate(status.updatedAt) ?? .distantPast) {
                return native
            }
        }
        return existing.max { modificationDate($0, fileManager: fm) < modificationDate($1, fileManager: fm) }
    }

    private static func candidates(for provider: String) -> [URL] {
        UsagePaths.providerUsageCandidates(provider)
    }

    private static func modificationDate(_ url: URL, fileManager fm: FileManager) -> Date {
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date ?? .distantPast
    }

    private static func mergeClaudeOfficialStatus(_ snapshot: UsageSnapshot, decoder: JSONDecoder, fileManager fm: FileManager) -> UsageSnapshot {
        var merged = snapshot
        guard let status = loadProviderHealth(
            filenames: ["claude-official-status.json"],
            decoder: decoder,
            fileManager: fm
        ) else { return merged }

        merged.officialUsageStatus = status
        if merged.providerHealth == nil, status.isWarning {
            merged.providerHealth = status
        }
        return merged
    }

    private static func loadProviderHealth(filenames: [String], decoder: JSONDecoder, fileManager fm: FileManager) -> UsageSnapshot.ProviderHealth? {
        for filename in filenames {
            guard let path = UsagePaths.stateDirectoriesForRead
                .map({ $0.appendingPathComponent(filename) })
                .filter({ fm.fileExists(atPath: $0.path) })
                .max(by: { modificationDate($0, fileManager: fm) < modificationDate($1, fileManager: fm) })
            else { continue }

            let health = healthCache.value(for: path) { url in
                (try? Data(contentsOf: url)).flatMap { try? decoder.decode(UsageSnapshot.ProviderHealth.self, from: $0) }
            }
            guard let health else { continue }
            return health
        }
        return nil
    }

    static func dropExpiredWindows(_ snapshot: UsageSnapshot, now: Date = Date(), calendar: Calendar = .current) -> UsageSnapshot {
        var cleaned = snapshot
        cleaned.currentSession = cleaned.currentSession.map { windowPreservingExpiredState($0, now: now, calendar: calendar) }
        cleaned.week = cleaned.week.map { windowPreservingExpiredState($0, now: now, calendar: calendar) }
        cleaned.weekFable = cleaned.weekFable.map { windowPreservingExpiredState($0, now: now, calendar: calendar) }
        cleaned.windows = cleaned.windows.map { windowPreservingExpiredState($0, now: now, calendar: calendar) }
        return cleaned
    }

    private static func windowPreservingExpiredState(
        _ window: UsageSnapshot.WindowMetric,
        now: Date,
        calendar: Calendar
    ) -> UsageSnapshot.WindowMetric {
        var preserved = window
        let resetPassed = UsageInsights.resetDate(for: window, now: now, calendar: calendar).map { $0 <= now } ?? false
        guard resetPassed || window.isExpired else { return preserved }
        preserved.state = "expired"
        preserved.lastKnownUsedPct = preserved.displayUsedPct
        preserved.usedPct = nil
        return preserved
    }

    private static func mergeGeminiQuotaSnapshot(_ quota: UsageSnapshot, withLocal local: UsageSnapshot) -> UsageSnapshot {
        var merged = quota
        if merged.session == nil {
            merged.session = local.session
        }
        if let localExtra = local.extraUsage, !localExtra.isEmpty {
            let quotaExtra = merged.extraUsage ?? ""
            merged.extraUsage = quotaExtra.isEmpty ? localExtra : "\(quotaExtra) · local \(localExtra)"
        }

        let localDrivers = local.contributors.map {
            UsageSnapshot.Contributor(
                percent: $0.percent,
                label: "Local \($0.label)",
                note: $0.note ?? "Derived from local Gemini session logs."
            )
        }
        if !localDrivers.isEmpty {
            merged.contributors = localDrivers + merged.contributors
        }
        return merged
    }
}

fileprivate func readTail(_ url: URL, maxBytes: Int) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
    try? handle.seek(toOffset: offset)
    var text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
    if offset > 0, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
    return text
}

enum CodexSessionReader {
    private static let maxFiles = 80
    private static let tailBytes = 2 * 1024 * 1024
    private static let tailCache = FileSignatureCache<(newest: Candidate, global: Candidate?)?>(limit: 160)

    static var tailParseCount: Int { tailCache.loads }

    static func loadSnapshot() -> UsageSnapshot? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sessions = home.appendingPathComponent(".codex/sessions")
        return loadSnapshot(fromSessionsRoot: sessions)
    }

    static func loadSnapshot(fromSessionsRoot sessions: URL) -> UsageSnapshot? {
        guard let files = newestJSONLFiles(in: sessions), !files.isEmpty else { return nil }

        var newestCandidate: Candidate?
        var globalCandidate: Candidate?
        for file in files.prefix(maxFiles) {
            if let globalCandidate, eventMillis(globalCandidate) >= file.modificationDate.timeIntervalSince1970 * 1000 {
                break
            }
            // A session file's newest rate-limit event only changes when the
            // file does, so key the tail parse by path + mtime + size.
            guard let candidate = tailCache.value(for: file.url, compute: { url in
                readTail(url, maxBytes: tailBytes).flatMap { candidate(fromTail: $0, path: file.path) }
            }) else { continue }
            if isNewer(candidate.newest, than: newestCandidate) { newestCandidate = candidate.newest }
            if let global = candidate.global {
                if isNewer(global, than: globalCandidate) { globalCandidate = global }
            }
        }
        let pick = globalCandidate ?? newestCandidate
        return pick.map { snapshot(from: $0.event, rate: $0.rate, path: $0.path) }
    }

    static func snapshot(fromTail tail: String, path: String) -> UsageSnapshot? {
        guard let candidate = candidate(fromTail: tail, path: path) else { return nil }
        let pick = candidate.global ?? candidate.newest
        return snapshot(from: pick.event, rate: pick.rate, path: pick.path)
    }

    private struct Candidate {
        let event: CodexEvent
        let rate: CodexEvent.RateLimits
        let path: String
    }

    private struct SessionFile {
        let url: URL
        let modificationDate: Date

        var path: String { url.path }
    }

    private static func isNewer(_ candidate: Candidate?, than previous: Candidate?) -> Bool {
        guard let candidate else { return false }
        guard let previous else { return true }
        return eventMillis(candidate) > eventMillis(previous)
    }

    private static func eventMillis(_ candidate: Candidate?) -> Double {
        guard let candidate else { return 0 }
        return timestampMillis(candidate.event.timestamp)
    }

    private static func timestampMillis(_ value: String?) -> Double {
        guard let value else { return 0 }
        if let date = isoWithFractional.date(from: value) ?? isoNoFractional.date(from: value) {
            return date.timeIntervalSince1970 * 1000
        }
        return 0
    }

    private static let isoWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoNoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func candidate(fromTail tail: String, path: String) -> (newest: Candidate, global: Candidate?)? {
        let decoder = JSONDecoder()
        var newestCandidate: Candidate?
        var globalCandidate: Candidate?

        for line in tail.split(separator: "\n").reversed() {
            guard line.contains("rate_limits"),
                  let data = String(line).data(using: .utf8),
                  let event = try? decoder.decode(CodexEvent.self, from: data),
                  let rate = event.payload?.rateLimits
            else { continue }

            if newestCandidate == nil {
                newestCandidate = Candidate(event: event, rate: rate, path: path)
            }
            if rate.limitId?.lowercased() == "codex" {
                globalCandidate = Candidate(event: event, rate: rate, path: path)
                break
            }
        }

        guard let newestCandidate else { return nil }
        return (newestCandidate, globalCandidate)
    }

    private static func newestJSONLFiles(in root: URL) -> [SessionFile]? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var files: [SessionFile] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else { continue }
            files.append(SessionFile(url: url, modificationDate: values.contentModificationDate ?? .distantPast))
        }

        return files.sorted { $0.modificationDate > $1.modificationDate }
    }

    private static func snapshot(from event: CodexEvent, rate: CodexEvent.RateLimits, path: String) -> UsageSnapshot {
        let total = event.payload?.info?.totalTokenUsage
        let last = event.payload?.info?.lastTokenUsage
        let plan = [rate.planType, rate.limitId].compactMap { $0 }.joined(separator: " / ")
        let classifiedWindows = classifyRateWindows(rate)
        let currentSession = classifiedWindows.first { $0.role == .session }?.window
        let week = classifiedWindows.first { $0.role == .week }?.window
        return UsageSnapshot(
            provider: "codex",
            displayName: "Codex",
            source: "codex sessions",
            sourceKind: "local_session_log",
            confidence: "high",
            confidenceNote: "Parsed from local Codex rate-limit events; not a billing API.",
            updatedAt: event.timestamp,
            eventAt: event.timestamp,
            session: UsageSnapshot.SessionMetrics(
                costUSD: nil,
                durationAPI: nil,
                durationWall: nil,
                codeAdded: nil,
                codeRemoved: nil,
                input: total?.inputTokens,
                output: total?.outputTokens,
                cacheRead: total?.cachedInputTokens,
                cacheWrite: nil,
                reasoningOutput: total?.reasoningOutputTokens,
                total: total?.totalTokens,
                lastInput: last?.inputTokens,
                lastOutput: last?.outputTokens,
                lastCacheRead: last?.cachedInputTokens,
                lastReasoningOutput: last?.reasoningOutputTokens,
                lastTotal: last?.totalTokens,
                contextWindow: event.payload?.info?.modelContextWindow
            ),
            currentSession: windowMetric(currentSession, fallbackLabel: "Codex 5h", id: "5h", eventAt: event.timestamp),
            week: windowMetric(week, fallbackLabel: "Codex weekly", id: "week", eventAt: event.timestamp),
            contributors: tokenContributors(total),
            skills: rateWindowItems(classifiedWindows),
            subagents: [],
            extraUsage: plan.isEmpty ? nil : plan,
            sourcePath: path
        )
    }

    private static func tokenContributors(_ usage: CodexEvent.TokenUsage?) -> [UsageSnapshot.Contributor] {
        guard let usage else { return [] }
        let total = Double(usage.totalTokens ?? 0)
        guard total > 0 else { return [] }

        let items: [(String, Int?, String?)] = [
            ("Input tokens", usage.inputTokens, nil),
            ("Cached input", usage.cachedInputTokens, nil),
            ("Output tokens", usage.outputTokens, nil),
            ("Reasoning output", usage.reasoningOutputTokens, nil)
        ]

        return items.compactMap { label, value, note in
            guard let value, value > 0 else { return nil }
            return UsageSnapshot.Contributor(
                percent: Double(value) / total * 100,
                label: label,
                note: note
            )
        }.sorted { $0.percent > $1.percent }
    }

    private enum RateWindowRole { case session, week, other }

    private struct ClassifiedRateWindow {
        var window: CodexEvent.Window
        var role: RateWindowRole
    }

    private static func classifyRateWindows(_ rate: CodexEvent.RateLimits) -> [ClassifiedRateWindow] {
        let raw = [rate.primary, rate.secondary].compactMap { $0 }
        var roles = raw.map(explicitWindowRole)
        for index in roles.indices where roles[index] == nil {
            if !roles.contains(where: { $0 == .session }) {
                roles[index] = .session
            } else if !roles.contains(where: { $0 == .week }) {
                roles[index] = .week
            } else {
                roles[index] = .other
            }
        }
        return zip(raw, roles).map { ClassifiedRateWindow(window: $0.0, role: $0.1 ?? .other) }
    }

    private static func explicitWindowRole(_ window: CodexEvent.Window) -> RateWindowRole? {
        switch window.windowMinutes {
        case 300: return .session
        case 10_080: return .week
        default: break
        }
        let label = [window.label, window.name, window.windowName, window.limitName, window.period, window.windowValue]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        if label.contains("week") || label.contains("7-day") || label.contains("7 day") || label.contains("7d") {
            return .week
        }
        if label.contains("5h") || label.contains("5 h") || label.contains("5-hour") || label.contains("5 hour") || label.contains("session") {
            return .session
        }
        return nil
    }

    private static func rateWindowItems(_ windows: [ClassifiedRateWindow]) -> [UsageSnapshot.RankedItem] {
        windows.compactMap { item in
            guard let used = item.window.usedPercent else { return nil }
            let fallback = item.role == .week ? "Weekly window" : item.role == .session ? "5h window" : "Usage window"
            return UsageSnapshot.RankedItem(
                name: windowLabel(minutes: item.window.windowMinutes) ?? item.window.label ?? item.window.name ?? fallback,
                percent: used
            )
        }
    }

    private static func windowMetric(
        _ window: CodexEvent.Window?,
        fallbackLabel: String,
        id: String,
        eventAt: String?
    ) -> UsageSnapshot.WindowMetric? {
        guard let window, let used = window.usedPercent else { return nil }
        let resetDate = window.resetsAt.map(Date.init(timeIntervalSince1970:))
        let expired = resetDate.map { $0 <= Date() } ?? false
        return UsageSnapshot.WindowMetric(
            label: windowLabel(minutes: window.windowMinutes) ?? fallbackLabel,
            usedPct: used,
            resetLabel: resetLabel(epoch: window.resetsAt),
            resetAt: resetDate.map { iso8601.string(from: $0) },
            id: id,
            eventAt: eventAt,
            state: expired ? "expired" : "live"
        )
    }

    private static let iso8601 = ISO8601DateFormatter()

    private static func windowLabel(minutes: Int?) -> String? {
        switch minutes {
        case 300: return "Codex 5h"
        case 10_080: return "Codex weekly"
        case 60: return "Codex 1h"
        case .some(let value): return "Codex \(value)m"
        case .none: return nil
        }
    }

    private static func resetLabel(epoch: Double?) -> String? {
        guard let epoch else { return nil }
        let date = Date(timeIntervalSince1970: epoch)
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            formatter.dateFormat = "MMM d HH:mm"
        } else {
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
        }
        return formatter.string(from: date)
    }

}

private struct CodexEvent: Decodable {
    let timestamp: String?
    let payload: Payload?

    struct Payload: Decodable {
        let info: Info?
        let rateLimits: RateLimits?

        enum CodingKeys: String, CodingKey {
            case info
            case rateLimits = "rate_limits"
        }
    }

    struct Info: Decodable {
        let totalTokenUsage: TokenUsage?
        let lastTokenUsage: TokenUsage?
        let modelContextWindow: Int?

        enum CodingKeys: String, CodingKey {
            case totalTokenUsage = "total_token_usage"
            case lastTokenUsage = "last_token_usage"
            case modelContextWindow = "model_context_window"
        }
    }

    struct TokenUsage: Decodable {
        let inputTokens: Int?
        let cachedInputTokens: Int?
        let outputTokens: Int?
        let reasoningOutputTokens: Int?
        let totalTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case cachedInputTokens = "cached_input_tokens"
            case outputTokens = "output_tokens"
            case reasoningOutputTokens = "reasoning_output_tokens"
            case totalTokens = "total_tokens"
        }
    }

    struct RateLimits: Decodable {
        let limitId: String?
        let planType: String?
        let primary: Window?
        let secondary: Window?

        enum CodingKeys: String, CodingKey {
            case limitId = "limit_id"
            case planType = "plan_type"
            case primary, secondary
        }
    }

    struct Window: Decodable {
        let usedPercent: Double?
        let windowMinutes: Int?
        let resetsAt: Double?
        let label: String?
        let name: String?
        let windowName: String?
        let limitName: String?
        let period: String?
        let windowValue: String?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case windowMinutes = "window_minutes"
            case resetsAt = "resets_at"
            case label, name, period
            case windowName = "window_name"
            case limitName = "limit_name"
            case windowValue = "window"
        }
    }
}

private enum GeminiSessionReader {
    private static let maxFiles = 20
    private static let tailBytes = 256 * 1024
    private static let fm = FileManager.default

    /// Listing and statting ~1000 chat files costs more than the 5 s refresh
    /// tick should; rescan at most this often.
    static let rescanInterval: TimeInterval = 30

    static func loadSnapshot() -> UsageSnapshot? {
        cacheLock.lock()
        if let hit = cached, Date().timeIntervalSince(hit.scannedAt) < rescanInterval {
            cacheLock.unlock()
            return hit.snapshot
        }
        cacheLock.unlock()
        let home = fm.homeDirectoryForCurrentUser
        let chatsRoot = home.appendingPathComponent(".gemini/tmp")
        guard let userDirs = try? fm.contentsOfDirectory(at: chatsRoot, includingPropertiesForKeys: nil) else { return nil }

        var files: [URL] = []
        for ud in userDirs {
            let chats = ud.appendingPathComponent("chats")
            if let f = try? fm.contentsOfDirectory(at: chats, includingPropertiesForKeys: [.contentModificationDateKey]) {
                files.append(contentsOf: f.filter { $0.pathExtension == "jsonl" })
            }
        }
        guard !files.isEmpty else { return nil }
        // Stat each file once (the old sort statted inside the comparator).
        let stamped = files.map { (url: $0, sig: FileSignature(url: $0)) }
            .sorted { ($0.sig?.modified ?? 0) > ($1.sig?.modified ?? 0) }
        files = stamped.map(\.url)

        // Reuse the last result while the 20 newest files are unchanged. The
        // today / 7-day sample ages with the clock, so cap reuse at 5 minutes.
        let signature = stamped.prefix(maxFiles).map { $0.sig ?? FileSignature(path: $0.url.path, modified: 0, size: 0) }
        let count = files.count
        cacheLock.lock()
        if var hit = cached, hit.signature == signature, hit.count == count,
           Date().timeIntervalSince(hit.at) < 300 {
            hit.scannedAt = Date()
            cached = hit
            cacheLock.unlock()
            return hit.snapshot
        }
        cacheLock.unlock()
        let snapshot = parse(files: files)
        cacheLock.lock()
        cached = (signature, count, Date(), Date(), snapshot)
        cacheLock.unlock()
        return snapshot
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cached: (signature: [FileSignature], count: Int, at: Date, scannedAt: Date, snapshot: UsageSnapshot?)?

    private static func parse(files: [URL]) -> UsageSnapshot? {
        let now = Date()
        let dayAgo = now.addingTimeInterval(-86_400)
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        var todayTotal = 0, weekTotal = 0, allInput = 0, allOutput = 0, allCached = 0, allThoughts = 0, allTotal = 0
        var modelTotals: [String: Int] = [:]
        var lastTotal: Int? = nil
        var latestEntry: Date? = nil

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        for file in files.prefix(maxFiles) {
            guard let text = readTail(file, maxBytes: tailBytes) else { continue }
            for line in text.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let tokens = obj["tokens"] as? [String: Any]
                else { continue }
                let total  = tokens["total"]    as? Int ?? 0
                let input  = tokens["input"]    as? Int ?? 0
                let output = tokens["output"]   as? Int ?? 0
                let cached = tokens["cached"]   as? Int ?? 0
                let thoughts = tokens["thoughts"] as? Int ?? 0
                allTotal    += total
                allInput    += input
                allOutput   += output
                allCached   += cached
                allThoughts += thoughts
                if let model = obj["model"] as? String {
                    modelTotals[model, default: 0] += total
                }
                if let ts = obj["timestamp"] as? String,
                   let date = iso.date(from: ts) ?? isoNoFrac.date(from: ts) {
                    if date > dayAgo  { todayTotal += total }
                    if date > weekAgo { weekTotal  += total }
                    if latestEntry == nil || date > latestEntry! {
                        latestEntry = date
                        lastTotal = total
                    }
                }
            }
        }
        guard allTotal > 0 else { return nil }

        let contributors: [UsageSnapshot.Contributor] = [
            ("Input", allInput),
            ("Cached input", allCached),
            ("Output", allOutput),
            ("Thoughts", allThoughts)
        ].compactMap { (label, val) in
            guard val > 0 else { return nil }
            return UsageSnapshot.Contributor(percent: Double(val) / Double(allTotal) * 100, label: label, note: nil)
        }.sorted { $0.percent > $1.percent }

        let modelItems: [UsageSnapshot.RankedItem] = modelTotals
            .sorted { $0.value > $1.value }
            .prefix(4)
            .map { UsageSnapshot.RankedItem(name: $0.key, percent: Double($0.value) / Double(allTotal) * 100) }

        return UsageSnapshot(
            provider: "gemini",
            displayName: "Gemini",
            source: "gemini sessions",
            sourceKind: "local_session_log",
            confidence: "medium",
            confidenceNote: "Derived from local Gemini session logs.",
            updatedAt: latestEntry.map { ISO8601DateFormatter().string(from: $0) },
            session: UsageSnapshot.SessionMetrics(
                costUSD: nil, durationAPI: nil, durationWall: nil,
                codeAdded: nil, codeRemoved: nil,
                input: allInput, output: allOutput,
                cacheRead: allCached, cacheWrite: nil,
                reasoningOutput: allThoughts,
                total: allTotal,
                lastInput: nil, lastOutput: nil, lastCacheRead: nil, lastReasoningOutput: nil,
                lastTotal: lastTotal,
                contextWindow: nil
            ),
            currentSession: nil,
            week: nil,
            contributors: contributors,
            skills: modelItems,
            subagents: [],
            extraUsage: "sample today \(formatCompact(todayTotal)) · 7d \(formatCompact(weekTotal))",
            sourcePath: files.first?.path
        )
    }

    private static func formatCompact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
