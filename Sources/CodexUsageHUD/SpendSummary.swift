import Foundation

// ============================================================================
//  Pure spend and activity summaries over the token readers.
//
//  `SpendSummary.current(now:)` and `ActivitySummary.current(now:)` are the
//  agent-facing entry points (JSON via `SpendJSON.encoder`); the panel and
//  the Activity window use the same `make` functions on the last scan.
//  Numbers, model ids and project folder names only.
// ============================================================================

/// Calendar windows every summary uses.
struct SpendPeriods: Equatable, Sendable {
    /// Local midnight today.
    var today: Date
    /// Midnight six days ago: the last 7 days including today.
    var week: Date
    /// Midnight 29 days ago: the last 30 days including today.
    var month: Date

    init(now: Date, calendar: Calendar = .current) {
        let midnight = calendar.startOfDay(for: now)
        today = midnight
        week = calendar.date(byAdding: .day, value: -6, to: midnight) ?? midnight.addingTimeInterval(-6 * 86_400)
        month = calendar.date(byAdding: .day, value: -29, to: midnight) ?? midnight.addingTimeInterval(-29 * 86_400)
    }

    static let daysPerMonth = 365.25 / 12

    /// A monthly price spread over `days` days.
    static func prorated(monthlyUSD: Double, days: Double) -> Double {
        monthlyUSD * days / daysPerMonth
    }
}

struct SpendSummary: Codable, Equatable, Sendable {
    struct Money: Codable, Equatable, Sendable {
        var today: Double = 0
        var week: Double = 0
        var month: Double = 0
        var currency = "USD"
        /// Some tokens were priced from a family default or an alias.
        var estimated = false
    }

    struct Tokens: Codable, Equatable, Sendable {
        var today = 0
        var week = 0
        var month = 0
    }

    struct Plan: Codable, Equatable, Sendable {
        var name: String?
        var monthlyUSD: Double?
        /// detected | user | unset
        var source: String
        var note: String?
    }

    struct Provider: Codable, Equatable, Sendable, Identifiable {
        var id: String { provider }
        /// Lane id: claude, codex, gemini, grok.
        var provider: String
        var name: String
        /// What these tokens would cost at API prices. Nil when this lane's
        /// logs are not read (Grok) or not on this Mac.
        var apiValue: Money?
        var tokens: Tokens?
        var plan: Plan
        /// Last-30-days API value ÷ what the plan costs for 30 days.
        var valueMultiple: Double?
        /// Model ids priced from a family default or an alias.
        var estimatedModels: [String] = []
        var hasLogs: Bool
    }

    struct Total: Codable, Equatable, Sendable {
        var apiValue = Money()
        /// Monthly prices of the plans that are set, added up.
        var planMonthlyUSD: Double?
        /// What those plans cost for the last 7 days (prorated).
        var paidWeekUSD: Double?
        /// API value of the lanes with a priced plan ÷ what they cost.
        var valueMultipleWeek: Double?
        var valueMultipleMonth: Double?
        /// Lanes with API value but no plan set.
        var lanesWithoutPlan: [String] = []
    }

    var generatedAt: Date
    var currency = "USD"
    /// Always false: API value is a yardstick, not a charge.
    var billed = false
    var note = "API value is what these tokens would cost at pay-per-use API prices. You are not billed for it."
    var periods = "today: since local midnight · week: last 7 days including today · month: last 30 days including today"
    var pricesCheckedOn = APIPricing.checked
    /// ready | no_logs
    var status: String
    var providers: [Provider]
    var total: Total

    func provider(_ id: String) -> Provider? {
        providers.first { $0.provider == id.lowercased() }
    }

    // MARK: Entry points

    /// For the agent interface and the CLI. Returns the running app's last
    /// summary when it is under two minutes old (milliseconds, and the
    /// app's own plan settings); otherwise reads the logs itself, which
    /// blocks for as long as a first scan takes.
    static func current(now: Date = Date()) -> SpendSummary {
        if let saved = SpendSnapshotFile.read(now: now) { return saved.spend }
        let roots = TokenLogRoots.current
        let scan = TokenUsageIndex.shared.scan(roots: roots, now: now, maxAge: TokenUsageIndex.rescanInterval)
        return make(scan: scan, plans: SpendPlans.resolved(scan: scan, roots: roots), now: now)
    }

    /// Pure: one summary from one scan.
    static func make(scan: TokenScan?, plans: [String: ResolvedPlan], now: Date, calendar: Calendar = .current) -> SpendSummary {
        let periods = SpendPeriods(now: now, calendar: calendar)
        var money: [AgentTool: Money] = [:]
        var tokens: [AgentTool: Tokens] = [:]
        var estimated: [AgentTool: Set<String>] = [:]

        for (tool, event) in SpendEvents.unique(scan?.files ?? []) where event.at >= periods.month && event.at <= now.addingTimeInterval(300) {
            let quote = APIPricing.quote(model: event.model, longContext: event.longContext, fast: event.fast, tool: tool)
            let usd = quote.rate.cost(event.counts)
            let count = event.counts.total
            var m = money[tool] ?? Money()
            var t = tokens[tool] ?? Tokens()
            m.month += usd; t.month += count
            if event.at >= periods.week { m.week += usd; t.week += count }
            if event.at >= periods.today { m.today += usd; t.today += count }
            if quote.estimated, usd > 0 {
                m.estimated = true
                estimated[tool, default: []].insert(APIPricing.normalize(event.model))
            }
            money[tool] = m
            tokens[tool] = t
        }

        let hasLogs = scan?.toolsWithLogs ?? []
        var providers: [Provider] = []
        for id in PlanCatalog.providers {
            let tool = AgentTool(rawValue: id)
            let plan = plans[id] ?? .unset
            let logs = tool.map { hasLogs.contains($0) } ?? false
            let value = tool.flatMap { t in logs ? (money[t] ?? Money()) : nil }
            var multiple: Double?
            if let value, let monthly = plan.monthlyUSD, monthly > 0 {
                multiple = value.month / SpendPeriods.prorated(monthlyUSD: monthly, days: 30)
            }
            providers.append(Provider(
                provider: id,
                name: PlanCatalog.providerName(id),
                apiValue: value,
                tokens: tool.flatMap { t in logs ? (tokens[t] ?? Tokens()) : nil },
                plan: Plan(name: plan.name, monthlyUSD: plan.monthlyUSD, source: plan.source.rawValue, note: plan.note),
                valueMultiple: multiple,
                estimatedModels: tool.map { (estimated[$0] ?? []).sorted() } ?? [],
                hasLogs: logs
            ))
        }

        var total = Total()
        var pairedValueWeek = 0.0, pairedValueMonth = 0.0, monthlySum = 0.0
        var anyPlanPrice = false
        for p in providers {
            if let v = p.apiValue {
                total.apiValue.today += v.today
                total.apiValue.week += v.week
                total.apiValue.month += v.month
                total.apiValue.estimated = total.apiValue.estimated || v.estimated
                if !p.plan.source.isEmpty, p.plan.source == ResolvedPlan.Source.unset.rawValue, v.month > 0 {
                    total.lanesWithoutPlan.append(p.provider)
                }
            }
            if let monthly = p.plan.monthlyUSD {
                anyPlanPrice = true
                monthlySum += monthly
                if let v = p.apiValue, monthly > 0 {
                    pairedValueWeek += v.week
                    pairedValueMonth += v.month
                }
            }
        }
        if anyPlanPrice {
            total.planMonthlyUSD = monthlySum
            let pairedMonthly = providers.compactMap { p -> Double? in
                guard p.apiValue != nil, let m = p.plan.monthlyUSD, m > 0 else { return nil }
                return m
            }.reduce(0, +)
            total.paidWeekUSD = SpendPeriods.prorated(monthlyUSD: monthlySum, days: 7)
            if pairedMonthly > 0 {
                total.valueMultipleWeek = pairedValueWeek / SpendPeriods.prorated(monthlyUSD: pairedMonthly, days: 7)
                total.valueMultipleMonth = pairedValueMonth / SpendPeriods.prorated(monthlyUSD: pairedMonthly, days: 30)
            }
        }

        return SpendSummary(
            generatedAt: now,
            status: hasLogs.isEmpty ? "no_logs" : "ready",
            providers: providers,
            total: total
        )
    }
}

// MARK: - Activity

struct ActivitySummary: Codable, Equatable, Sendable {
    struct Session: Codable, Equatable, Sendable, Identifiable {
        /// "<tool>:<session id>"
        var id: String
        var tool: String
        var toolName: String
        /// Working folder's last component only.
        var project: String
        /// The model that cost the most in the window.
        var model: String
        var models: [String]
        var startedAt: Date
        var lastActiveAt: Date
        /// Inside the window, cache included.
        var tokens: Int
        var apiValueUSD: Double
        /// Spend over the last 60 minutes.
        var tokensPerHour: Int
        var usdPerHour: Double
        var estimated: Bool
        /// Helper threads (Claude subagents, Codex forks) folded into this session.
        var helpers: Int
    }

    struct ToolGroup: Codable, Equatable, Sendable, Identifiable {
        var id: String { tool }
        var tool: String
        var toolName: String
        var sessions: [Session]
        var tokens: Int
        var apiValueUSD: Double
        var usdPerHour: Double
    }

    var generatedAt: Date
    /// The earlier of local midnight and five hours ago.
    var windowStart: Date
    var windowLabel = "today and the last 5 hours"
    /// Newest first.
    var sessions: [Session]
    var groups: [ToolGroup]
    /// The session spending fastest over the last hour, if any is.
    var topBurner: Session?
    var totalTokens: Int
    var totalAPIValueUSD: Double
    /// ready | no_logs
    var status: String
    var billed = false

    static let burnWindow: TimeInterval = 3600
    static let recentWindow: TimeInterval = 5 * 3600

    /// For the agent interface and the CLI; see `SpendSummary.current`.
    static func current(now: Date = Date()) -> ActivitySummary {
        if let saved = SpendSnapshotFile.read(now: now) { return saved.activity }
        let scan = TokenUsageIndex.shared.scan(roots: .current, now: now, maxAge: TokenUsageIndex.rescanInterval)
        return make(scan: scan, now: now)
    }

    static func make(scan: TokenScan?, now: Date, calendar: Calendar = .current) -> ActivitySummary {
        let windowStart = min(calendar.startOfDay(for: now), now.addingTimeInterval(-recentWindow))
        let burnStart = now.addingTimeInterval(-burnWindow)

        struct Accumulator {
            var tool: AgentTool
            var rootID: String
            var project: String?
            var helperProjects: [String] = []
            var start = Date.distantFuture
            var last = Date.distantPast
            var tokens = 0
            var usd = 0.0
            var burnTokens = 0
            var burnUSD = 0.0
            var estimated = false
            var modelUSD: [String: Double] = [:]
            var files = Set<Int>()
        }

        var sessions: [String: Accumulator] = [:]
        for (tool, file, event) in SpendEvents.uniqueWithFiles(scan?.files ?? []) where event.at >= windowStart && event.at <= now.addingTimeInterval(300) {
            let root = file.parentSessionID ?? file.sessionID
            let key = "\(tool.rawValue):\(root)"
            var acc = sessions[key] ?? Accumulator(tool: tool, rootID: root)
            let isRoot = file.parentSessionID == nil
            if isRoot, acc.project == nil || acc.project == ProjectName.unknown { acc.project = file.project }
            else if !isRoot { acc.helperProjects.append(file.project) }
            acc.files.insert(file.fileKey)
            let quote = APIPricing.quote(model: event.model, longContext: event.longContext, fast: event.fast, tool: tool)
            let usd = quote.rate.cost(event.counts)
            acc.start = min(acc.start, event.at)
            acc.last = max(acc.last, event.at)
            acc.tokens += event.counts.total
            acc.usd += usd
            if event.at >= burnStart {
                acc.burnTokens += event.counts.total
                acc.burnUSD += usd
            }
            if quote.estimated, usd > 0 { acc.estimated = true }
            acc.modelUSD[APIPricing.normalize(event.model), default: 0] += max(usd, 1e-9 * Double(event.counts.total))
            sessions[key] = acc
        }

        let rows: [Session] = sessions.map { key, acc in
            let models = acc.modelUSD.sorted { $0.value > $1.value }.map(\.key)
            let project = acc.project ?? acc.helperProjects.first ?? ProjectName.unknown
            let burnHours = burnWindow / 3600
            return Session(
                id: key,
                tool: acc.tool.rawValue,
                toolName: acc.tool.displayName,
                project: project,
                model: models.first ?? "unknown",
                models: models,
                startedAt: acc.start,
                lastActiveAt: acc.last,
                tokens: acc.tokens,
                apiValueUSD: acc.usd,
                tokensPerHour: Int(Double(acc.burnTokens) / burnHours),
                usdPerHour: acc.burnUSD / burnHours,
                estimated: acc.estimated,
                helpers: max(0, acc.files.count - 1)
            )
        }
        .sorted { $0.lastActiveAt != $1.lastActiveAt ? $0.lastActiveAt > $1.lastActiveAt : $0.id < $1.id }

        let groups: [ToolGroup] = AgentTool.allCases.compactMap { tool in
            let mine = rows.filter { $0.tool == tool.rawValue }
            guard !mine.isEmpty else { return nil }
            return ToolGroup(
                tool: tool.rawValue,
                toolName: tool.displayName,
                sessions: mine,
                tokens: mine.reduce(0) { $0 + $1.tokens },
                apiValueUSD: mine.reduce(0) { $0 + $1.apiValueUSD },
                usdPerHour: mine.reduce(0) { $0 + $1.usdPerHour }
            )
        }

        let top = rows.filter { $0.usdPerHour > 0.005 }.max { $0.usdPerHour < $1.usdPerHour }
        return ActivitySummary(
            generatedAt: now,
            windowStart: windowStart,
            sessions: rows,
            groups: groups,
            topBurner: top,
            totalTokens: rows.reduce(0) { $0 + $1.tokens },
            totalAPIValueUSD: rows.reduce(0) { $0 + $1.apiValueUSD },
            status: (scan?.toolsWithLogs.isEmpty ?? true) ? "no_logs" : "ready"
        )
    }
}

// MARK: - Shared

/// Events across files, each counted once. A resumed Claude session can
/// copy earlier messages into a new file; message id + request id decides.
enum SpendEvents {
    static func unique(_ files: [TokenLogFile]) -> [(AgentTool, TokenEvent)] {
        uniqueWithFiles(files).map { ($0.0, $0.2) }
    }

    static func uniqueWithFiles(_ files: [TokenLogFile]) -> [(AgentTool, TokenLogFile, TokenEvent)] {
        var seen = Set<String>()
        var out: [(AgentTool, TokenLogFile, TokenEvent)] = []
        out.reserveCapacity(files.reduce(0) { $0 + $1.events.count })
        for file in files {
            for event in file.events {
                if let key = event.key {
                    guard seen.insert(key).inserted else { continue }
                }
                out.append((file.tool, file, event))
            }
        }
        return out
    }
}

/// Plan per lane from the user's choice and what this Mac shows.
enum SpendPlans {
    static func resolved(scan: TokenScan?, roots: TokenLogRoots, defaults: UserDefaults = .standard) -> [String: ResolvedPlan] {
        var out: [String: ResolvedPlan] = [:]
        for provider in PlanCatalog.providers {
            let choice = PlanSettings.choice(for: provider, defaults: defaults)
            let detected = choice == .auto ? PlanDetection.detect(provider: provider, scan: scan, roots: roots) : nil
            out[provider] = ResolvedPlan.resolve(choice: choice, detected: detected)
        }
        return out
    }
}

/// JSON for agents: ISO-8601 dates, stable key order.
enum SpendJSON {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }
}

/// Recomputes summaries only when the scan, the plans or the minute change,
/// so the panel's 5-second refresh costs a dictionary lookup.
final class SpendMemo: @unchecked Sendable {
    static let shared = SpendMemo()
    private let lock = NSLock()
    private var spendKey: String?
    private var spend: SpendSummary?
    private var activityKey: String?
    private var activity: ActivitySummary?

    func spend(scan: TokenScan, plans: [String: ResolvedPlan], now: Date) -> SpendSummary {
        let key = "\(scan.scannedAt.timeIntervalSince1970)|\(Int(now.timeIntervalSince1970 / 60))|\(plans.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.planID ?? "")/\($0.value.monthlyUSD ?? -1)/\($0.value.source.rawValue)" }.joined(separator: ","))"
        lock.lock()
        if key == spendKey, let spend { lock.unlock(); return spend }
        lock.unlock()
        let fresh = SpendSummary.make(scan: scan, plans: plans, now: now)
        lock.lock(); spendKey = key; spend = fresh; lock.unlock()
        return fresh
    }

    func activity(scan: TokenScan, now: Date) -> ActivitySummary {
        let key = "\(scan.scannedAt.timeIntervalSince1970)|\(Int(now.timeIntervalSince1970 / 30))"
        lock.lock()
        if key == activityKey, let activity { lock.unlock(); return activity }
        lock.unlock()
        let fresh = ActivitySummary.make(scan: scan, now: now)
        lock.lock(); activityKey = key; activity = fresh; lock.unlock()
        return fresh
    }
}

/// `CODEX_USAGE_HUD_SPEND_PROBE=<path>`: one scan, both summaries as JSON.
enum SpendProbe {
    struct Output: Encodable {
        var spend: SpendSummary
        var activity: ActivitySummary
        var scanSeconds: Double
        var rescanSeconds: Double
        var filesRead: Int
    }

    static func run(outputPath: String) -> Int32 {
        let now = Date()
        let roots = TokenLogRoots.current
        let scan = TokenUsageIndex.shared.scan(roots: roots, now: now)
        let again = TokenUsageIndex.shared.scan(roots: roots, now: now)
        let output = Output(
            spend: SpendSummary.make(scan: scan, plans: SpendPlans.resolved(scan: scan, roots: roots), now: now),
            activity: ActivitySummary.make(scan: scan, now: now),
            scanSeconds: scan.duration,
            rescanSeconds: again.duration,
            filesRead: scan.filesParsed
        )
        guard let data = try? SpendJSON.encoder.encode(output) else { return 1 }
        do { try data.write(to: URL(fileURLWithPath: outputPath)) } catch { return 1 }
        FileHandle.standardError.write(Data("spend probe: \(scan.filesParsed) files in \(String(format: "%.2f", scan.duration))s, rescan \(String(format: "%.3f", again.duration))s\n".utf8))
        return 0
    }
}

/// `spend-summary.json` in the state dir: the app's last spend and activity
/// summaries (numbers, model ids, project folder names), rewritten at most
/// once a minute. Lets a short-lived CLI or agent tool answer without
/// re-reading the session logs.
enum SpendSnapshotFile {
    static let filename = "spend-summary.json"
    static let maxAge: TimeInterval = 120

    struct Payload: Codable, Equatable {
        var spend: SpendSummary
        var activity: ActivitySummary
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastWritten: Date?

    static func url(stateDirectory: URL = UsagePaths.stateDirectory) -> URL {
        stateDirectory.appendingPathComponent(filename)
    }

    /// The saved payload when it is fresh and describes the live logs.
    static func read(now: Date, stateDirectory: URL = UsagePaths.stateDirectory,
                     env: [String: String] = ProcessInfo.processInfo.environment) -> Payload? {
        // A fixture or test pointing the readers elsewhere never gets the
        // app's live numbers back.
        if let setting = env["CODEX_USAGE_HUD_TOKEN_LOGS"], !setting.isEmpty, setting != "live" { return nil }
        guard let data = try? Data(contentsOf: url(stateDirectory: stateDirectory)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data) else { return nil }
        let age = now.timeIntervalSince(payload.spend.generatedAt)
        guard age >= -60, age < maxAge else { return nil }
        return payload
    }

    /// Writes when the spend summary is newer than the last one written.
    static func writeIfNewer(spend: SpendSummary, scan: TokenScan, stateDirectory: URL = UsagePaths.stateDirectory) {
        lock.lock()
        if let lastWritten, lastWritten >= spend.generatedAt { lock.unlock(); return }
        lastWritten = spend.generatedAt
        lock.unlock()
        let payload = Payload(spend: spend, activity: SpendMemo.shared.activity(scan: scan, now: spend.generatedAt))
        guard let data = try? SpendJSON.encoder.encode(payload) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let target = url(stateDirectory: stateDirectory)
        let temp = stateDirectory.appendingPathComponent(".\(filename).\(UUID().uuidString)")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temp.path, target.path) != 0 { try? fm.removeItem(at: temp) }
    }
}
