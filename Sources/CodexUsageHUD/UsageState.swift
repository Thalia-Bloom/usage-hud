import Foundation
import SwiftUI
import Darwin

struct UsageSnapshot: Identifiable, Decodable, Sendable {
    struct SessionMetrics: Decodable, Sendable {
        var costUSD: Double?
        var durationAPI: String?
        var durationWall: String?
        var codeAdded: Int?
        var codeRemoved: Int?
        var input: Int?
        var output: Int?
        var cacheRead: Int?
        var cacheWrite: Int?
        var reasoningOutput: Int?
        var total: Int?
        var lastInput: Int?
        var lastOutput: Int?
        var lastCacheRead: Int?
        var lastReasoningOutput: Int?
        var lastTotal: Int?
        var contextWindow: Int?
        var todayTotal: Int? = nil
        var weekTotal: Int? = nil
        var requestCount: Int? = nil
    }

    struct WindowMetric: Decodable, Sendable {
        var id: String?
        var label: String?
        var usedPct: Double?
        var used: Double?
        var limit: Double?
        var resetLabel: String?
        var resetAt: String?
        var eventAt: String?
        var state: String?
        var reason: String?
        /// Per-window capture stamp (weekFable only today): the snapshot-level
        /// capturedAt is re-stamped by the statusline tap, so an opt-in-fetched
        /// window needs its own age to stay honest.
        var capturedAt: String?

        /// Expired schema-v2 windows retain the final observed percentage for
        /// the grey IDLE treatment, while `usedPct` becomes nil so budget and
        /// menu-bar verdict calculations cannot mistake old usage for live cap.
        var lastKnownUsedPct: Double?

        var displayUsedPct: Double? { usedPct ?? lastKnownUsedPct }
        var normalizedState: String? { state?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        var isExpired: Bool { normalizedState == "expired" }
        var isUnknown: Bool { normalizedState == "unknown" }

        enum CodingKeys: String, CodingKey {
            case id, label, usedPct, used, limit, resetLabel, resetAt, eventAt, state, reason, capturedAt
        }

        init(
            label: String? = nil,
            usedPct: Double? = nil,
            resetLabel: String? = nil,
            resetAt: String? = nil,
            capturedAt: String? = nil,
            id: String? = nil,
            used: Double? = nil,
            limit: Double? = nil,
            eventAt: String? = nil,
            state: String? = nil,
            reason: String? = nil,
            lastKnownUsedPct: Double? = nil
        ) {
            self.id = id
            self.label = label
            self.used = used
            self.limit = limit
            self.resetLabel = resetLabel
            self.resetAt = resetAt
            self.eventAt = eventAt
            self.state = state
            self.reason = reason
            self.capturedAt = capturedAt
            if ["expired", "unknown"].contains(state?.lowercased() ?? "") {
                self.usedPct = nil
                self.lastKnownUsedPct = lastKnownUsedPct ?? usedPct
            } else {
                self.usedPct = usedPct
                self.lastKnownUsedPct = lastKnownUsedPct
            }
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decodeIfPresent(String.self, forKey: .id)
            label = try values.decodeIfPresent(String.self, forKey: .label)
            used = try values.decodeIfPresent(Double.self, forKey: .used)
            limit = try values.decodeIfPresent(Double.self, forKey: .limit)
            resetLabel = try values.decodeIfPresent(String.self, forKey: .resetLabel)
            resetAt = try values.decodeIfPresent(String.self, forKey: .resetAt)
            eventAt = try values.decodeIfPresent(String.self, forKey: .eventAt)
            state = try values.decodeIfPresent(String.self, forKey: .state)
            reason = try values.decodeIfPresent(String.self, forKey: .reason)
            capturedAt = try values.decodeIfPresent(String.self, forKey: .capturedAt)
            let decodedUsedPct = try values.decodeIfPresent(Double.self, forKey: .usedPct)
            if ["expired", "unknown"].contains(state?.lowercased() ?? "") {
                usedPct = nil
                lastKnownUsedPct = decodedUsedPct
            } else {
                usedPct = decodedUsedPct
                lastKnownUsedPct = nil
            }
        }
    }

    struct Contributor: Identifiable, Decodable, Sendable {
        var id: String { "\(index)-\(percent)-\(label)" }
        var index: Int = 0
        var percent: Double
        var label: String
        var note: String?

        enum CodingKeys: String, CodingKey {
            case percent, label, note
        }

        init(percent: Double, label: String, note: String? = nil) {
            self.percent = percent
            self.label = label
            self.note = note
        }

        // A missing percent must not sink the whole snapshot — an info-only
        // driver row decodes as 0 and simply sorts last.
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            percent = try values.decodeIfPresent(Double.self, forKey: .percent) ?? 0
            label = try values.decodeIfPresent(String.self, forKey: .label) ?? ""
            note = try values.decodeIfPresent(String.self, forKey: .note)
        }
    }

    struct RankedItem: Identifiable, Decodable, Sendable {
        var id: String { name }
        var name: String
        var percent: Double
    }

    /// Writer-computed lane health (schema v2): one verdict per lane, written by
    /// the producer that owns the lane. fresh | stale | degraded | broken |
    /// not_set_up (an empty Grok lane without configuration or prior usage).
    struct LaneHealth: Decodable, Sendable {
        var verdict: String?
        var reason: String?
        var checkedAt: String?

        var isNotSetUp: Bool { verdict?.lowercased() == "not_set_up" }

        var isWarning: Bool {
            guard let verdict = verdict?.lowercased() else { return false }
            return ["stale", "degraded", "broken", "unauthorized", "invalid"].contains(verdict)
        }
    }

    struct ProviderHealth: Decodable, Sendable {
        var status: String?
        var reason: String?
        var message: String?
        var updatedAt: String?
        var retryAt: String?
        var exitCode: Int?
        var signal: String?

        var isWarning: Bool {
            if let exitCode, exitCode != 0 { return true }
            if let signal, !signal.isEmpty { return true }
            let value = (status ?? reason ?? "").lowercased()
            return !value.isEmpty && !["ok", "ready", "available"].contains(value)
        }
    }

    var id: String { provider }
    var schemaVersion: Int
    var provider: String
    var displayName: String?
    var source: String?
    var sourceKind: String?
    var confidence: String?
    var confidenceNote: String?
    var updatedAt: String?
    var capturedAt: String?
    var eventAt: String?
    var session: SessionMetrics?
    var currentSession: WindowMetric?
    var week: WindowMetric?
    /// Claude only: the official per-model weekly limit for Fable, parsed from
    /// /usage ("Current week (Fable)"). Distinct from the all-models week.
    var weekFable: WindowMetric?
    var windows: [WindowMetric]
    var contributors: [Contributor]
    var skills: [RankedItem]
    var subagents: [RankedItem]
    var extraUsage: String?
    var sourcePath: String?
    var loadedFromPath: String?
    var providerHealth: ProviderHealth?
    var officialUsageStatus: ProviderHealth?
    var health: LaneHealth?
    /// Windows the statusline tap cleared as expired since the last reset
    /// (e.g. "weekFable"), plus when. Lets the UI tell "no reading yet" apart
    /// from "reading expired" instead of defaulting either to 0%.
    var rateLimitExpired: [String]?
    var rateLimitExpiredAt: String?
    /// Prepaid credits the provider draws on after the plan's own limit runs
    /// out (Codex reports these beside its rate limits).
    var credits: Credits? = nil

    struct Credits: Decodable, Sendable, Equatable {
        var hasCredits: Bool?
        var unlimited: Bool?
        var balance: Double?
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, provider, displayName, source, sourceKind, confidence, confidenceNote
        case updatedAt, capturedAt, eventAt, session
        case currentSession, week, weekFable, windows, contributors, skills, subagents, extraUsage
        case sourcePath, providerHealth, officialUsageStatus, health, rateLimitExpired, rateLimitExpiredAt
        case credits
    }

    init(
        schemaVersion: Int = 1,
        provider: String,
        displayName: String? = nil,
        source: String? = nil,
        sourceKind: String? = nil,
        confidence: String? = nil,
        confidenceNote: String? = nil,
        updatedAt: String? = nil,
        capturedAt: String? = nil,
        eventAt: String? = nil,
        session: SessionMetrics? = nil,
        currentSession: WindowMetric? = nil,
        week: WindowMetric? = nil,
        weekFable: WindowMetric? = nil,
        windows: [WindowMetric] = [],
        contributors: [Contributor] = [],
        skills: [RankedItem] = [],
        subagents: [RankedItem] = [],
        extraUsage: String? = nil,
        sourcePath: String? = nil,
        loadedFromPath: String? = nil,
        providerHealth: ProviderHealth? = nil,
        officialUsageStatus: ProviderHealth? = nil,
        health: LaneHealth? = nil,
        rateLimitExpired: [String]? = nil,
        rateLimitExpiredAt: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.displayName = displayName
        self.source = source
        self.sourceKind = sourceKind
        self.confidence = confidence
        self.confidenceNote = confidenceNote
        self.updatedAt = updatedAt
        self.capturedAt = capturedAt
        self.eventAt = eventAt
        self.session = session
        self.currentSession = currentSession
        self.week = week
        self.weekFable = weekFable
        self.windows = windows
        self.contributors = contributors
        self.skills = skills
        self.subagents = subagents
        self.extraUsage = extraUsage
        self.sourcePath = sourcePath
        self.loadedFromPath = loadedFromPath
        self.providerHealth = providerHealth
        self.officialUsageStatus = officialUsageStatus
        self.health = health
        self.rateLimitExpired = rateLimitExpired
        self.rateLimitExpiredAt = rateLimitExpiredAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        provider = try values.decodeIfPresent(String.self, forKey: .provider) ?? "unknown"
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName)
        source = try values.decodeIfPresent(String.self, forKey: .source)
        sourceKind = try values.decodeIfPresent(String.self, forKey: .sourceKind)
        confidence = try values.decodeIfPresent(String.self, forKey: .confidence)
        confidenceNote = try values.decodeIfPresent(String.self, forKey: .confidenceNote)
        updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt)
        capturedAt = try values.decodeIfPresent(String.self, forKey: .capturedAt)
        eventAt = try values.decodeIfPresent(String.self, forKey: .eventAt)
        session = try values.decodeIfPresent(SessionMetrics.self, forKey: .session)
        credits = try? values.decodeIfPresent(Credits.self, forKey: .credits)
        let legacyCurrentSession = try values.decodeIfPresent(WindowMetric.self, forKey: .currentSession)
        let legacyWeek = try values.decodeIfPresent(WindowMetric.self, forKey: .week)
        let legacyWeekFable = try values.decodeIfPresent(WindowMetric.self, forKey: .weekFable)
        windows = try values.decodeIfPresent([WindowMetric].self, forKey: .windows) ?? []
        // During the dual-write transition a matching windows[] entry is the
        // authority, including an honest expired/unknown state. Legacy v1
        // fields remain the fallback until every writer emits schema v2.
        currentSession = Self.preferredWindow(in: windows, provider: provider, role: .session) ?? legacyCurrentSession
        week = Self.preferredWindow(in: windows, provider: provider, role: .week) ?? legacyWeek
        weekFable = Self.preferredWindow(in: windows, provider: provider, role: .fableWeek) ?? legacyWeekFable
        var rawContributors = try values.decodeIfPresent([Contributor].self, forKey: .contributors) ?? []
        for i in rawContributors.indices { rawContributors[i].index = i }
        contributors = rawContributors
        skills = try values.decodeIfPresent([RankedItem].self, forKey: .skills) ?? []
        subagents = try values.decodeIfPresent([RankedItem].self, forKey: .subagents) ?? []
        extraUsage = try values.decodeIfPresent(String.self, forKey: .extraUsage)
        sourcePath = try values.decodeIfPresent(String.self, forKey: .sourcePath)
        loadedFromPath = nil
        providerHealth = try values.decodeIfPresent(ProviderHealth.self, forKey: .providerHealth)
        officialUsageStatus = try values.decodeIfPresent(ProviderHealth.self, forKey: .officialUsageStatus)
        health = try values.decodeIfPresent(LaneHealth.self, forKey: .health)
        rateLimitExpired = try values.decodeIfPresent([String].self, forKey: .rateLimitExpired)
        rateLimitExpiredAt = try values.decodeIfPresent(String.self, forKey: .rateLimitExpiredAt)
    }

    private enum WindowRole { case session, week, fableWeek }

    private static func preferredWindow(in windows: [WindowMetric], provider: String, role: WindowRole) -> WindowMetric? {
        let providerKey = provider.lowercased()
        return windows.compactMap { window -> (WindowMetric, Int)? in
            let id = window.id?.lowercased() ?? ""
            let label = window.label?.lowercased() ?? ""
            let text = "\(id) \(label)"
            let matchesRole: Bool
            switch role {
            case .session:
                matchesRole = text.contains("5h") || text.contains("session")
            case .week:
                matchesRole = text.contains("week") && !text.contains("fable")
            case .fableWeek:
                matchesRole = text.contains("fable") && text.contains("week")
            }
            guard matchesRole else { return nil }

            var score = 10
            if id == "5h" && role == .session { score += 80 }
            if id == "week" && role == .week { score += 80 }
            if id == "fable-week" && role == .fableWeek { score += 80 }
            if id == providerKey || id.hasPrefix("\(providerKey)-") || label.hasPrefix(providerKey) {
                score += 100
            }
            return (window, score)
        }
        .max { $0.1 < $1.1 }?.0
    }
}

@MainActor
final class UsageState: ObservableObject {
    let resetPings = ResetPingController()
    let mobileSnapshot = ICloudSnapshotPublisher()
    @Published private(set) var showOnMobile = false

    func setShowOnMobile(_ enabled: Bool) {
        mobileSnapshot.setEnabled(enabled)
        showOnMobile = enabled
        publishMobileSnapshot()
    }

    private func publishMobileSnapshot() {
        // Isolated fixtures and offscreen renderers must never touch iCloud.
        guard !UsagePaths.isIsolatedStateDir,
              !ProcessInfo.processInfo.environment.keys.contains(where: { $0.hasPrefix("CODEX_USAGE_HUD_") && $0.contains("SNAPSHOT") }),
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        mobileSnapshot.initializeAfterSetup(BackgroundRefreshService.isInstalled())
        showOnMobile = mobileSnapshot.enabled
        guard showOnMobile else { return }
        mobileSnapshot.publish(.make(snapshots: snapshots, selection: ProviderPreferences.selection(),
                                    mac: Host.current().localizedName ?? "Mac"))
    }

    @Published private(set) var snapshots: [UsageSnapshot] = []
    @Published private(set) var lastLoadedAt: Date?
    @Published private(set) var loadError: String?
    @Published private(set) var budget: BudgetState?            // claude (back-compat)
    @Published private(set) var budgets: [String: BudgetState] = [:]  // per-provider
    @Published private(set) var overrideUntil: Date?
    @Published private(set) var preferencesRevision = 0
    @Published var setupCard: SetupCardModel = .hidden
    @Published private(set) var setupBusy = false
    @Published private(set) var isManualRefreshing = false
    @Published private(set) var manualRefreshFeedback: ManualRefreshFeedback?
    @Published var activeRecoveryProvider: String?
    /// API value and plans from the token readers. Nil until the first scan
    /// of the session logs finishes (it runs off the main thread).
    @Published private(set) var spend: SpendSummary?

    var onSnapshotsChange: (([UsageSnapshot]) -> Void)?
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?
    private var manualRefreshTask: Task<Void, Never>?
    private var preferencesObserver: NSObjectProtocol?
    private var planObserver: NSObjectProtocol?
    private var detectionCache: (summary: DetectionSummary, at: Date)?
    private static let detectionTTL: TimeInterval = 300

    func start() {
        timer?.invalidate()
        if preferencesObserver == nil {
            preferencesObserver = NotificationCenter.default.addObserver(
                forName: .usageHUDProviderPreferencesDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.preferencesRevision += 1
                    self.detectionCache = nil
                    self.onSnapshotsChange?(self.snapshots)
                    self.refresh()
                }
            }
        }
        if planObserver == nil {
            planObserver = NotificationCenter.default.addObserver(
                forName: PlanSettings.didChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        refresh()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Synchronous load for the offscreen snapshot renderer, which captures on
    /// a pumped run loop that can't wait on the async refresh pipeline.
    func refreshNow() {
        applyRefresh(Self.prepareRefresh(blockingTokenScan: true))
    }

    func refresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            let prepared = await Task.detached(priority: .utility) {
                UsageState.prepareRefresh()
            }.value
            guard let self else { return }
            defer { self.refreshTask = nil }
            guard !Task.isCancelled else { return }
            self.applyRefresh(prepared)
        }
    }

    func notePanelOpened() {
        if setupCard.phase == .doneWithData && !setupCard.needsAttention {
            dismissSetupSummary()
        }
    }

    func dismissSetupSummary() {
        ProviderPreferences.acknowledgeSetupComplete()
        setupCard = .hidden
    }

    func runSetup() {
        guard !setupBusy else { return }
        detectionCache = nil
        let summary = ProviderPreferences.detectionSummary() ?? ToolDetection.detect()
        let providers = summary.foundCustomerIds.isEmpty
            ? DetectionSummary.customerOrder.map(\.id)
            : summary.foundCustomerIds
        setupBusy = true
        setupCard = .running(summary: summary)
        setupTask?.cancel()
        setupTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                BackgroundRefreshService.setUpAndRefresh(
                    paths: .resolved(),
                    providers: providers
                )
            }.value
            guard let self, !Task.isCancelled else { return }
            self.refreshNow()
            // A blocked Set up installed nothing, so readings already on disk
            // say nothing about it; the card shows the real reason instead.
            let hasData = outcome.blocker == nil && (outcome.hasData || self.snapshots.contains { snap in
                snap.week?.usedPct != nil || snap.currentSession?.usedPct != nil || snap.session?.todayTotal != nil
            })
            self.setupCard = .outcome(summary: summary, outcome: outcome, hasData: hasData)
            self.setupBusy = false
        }
    }

    /// A fresh install sets itself up: the first-run panel goes straight into
    /// Set up for the tools found, so nobody has to find the button. Skipped
    /// when nothing was found or this copy can't install (wrong location);
    /// the card explains either case and keeps its button.
    nonisolated static func shouldAutoRunSetup(installed: Bool, busy: Bool, found: [String], locationIssue: String?) -> Bool {
        !installed && !busy && !found.isEmpty && locationIssue == nil
    }

    func runFirstRunSetupIfReady() {
        let summary = ProviderPreferences.detectionSummary() ?? ToolDetection.detect()
        let issue = BackgroundRefreshService.installLocationIssue(
            appExecutable: Bundle.main.executablePath ?? CommandLine.arguments.first ?? "",
            home: UsagePaths.home
        )
        guard Self.shouldAutoRunSetup(
            installed: BackgroundRefreshService.isInstalled(),
            busy: setupBusy,
            found: summary.foundCustomerIds,
            locationIssue: issue
        ) else { return }
        runSetup()
    }

    func forceBudgetRefresh(
        run: @escaping @Sendable () -> ManualRefreshOutcome = { ManualRefreshService.run() },
        prepare: @escaping @Sendable () -> PreparedUsageRefresh = { UsageState.prepareRefresh() }
    ) {
        guard !isManualRefreshing, !setupBusy else { return }
        isManualRefreshing = true
        manualRefreshFeedback = .refreshing
        let before = snapshots
        let providers = Set(UsageInsights.visibleProviderOrder(snapshots: snapshots))
        onSnapshotsChange?(snapshots)
        manualRefreshTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { run() }.value
            let prepared = await Task.detached(priority: .utility) { prepare() }.value
            guard let self, !Task.isCancelled else { return }
            self.applyRefresh(prepared)
            self.manualRefreshFeedback = .finished(
                outcome, before: before, after: self.snapshots, providers: providers
            )
            self.isManualRefreshing = false
            self.manualRefreshTask = nil
            self.onSnapshotsChange?(self.snapshots)
        }
    }

    func toggleRecovery(for provider: String) {
        let id = provider.lowercased()
        activeRecoveryProvider = (activeRecoveryProvider == id) ? nil : id
        NotificationCenter.default.post(name: PanelMetrics.heightDidChange, object: nil)
    }

    deinit {
        timer?.invalidate()
        refreshTask?.cancel()
        setupTask?.cancel()
        manualRefreshTask?.cancel()
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
        if let planObserver { NotificationCenter.default.removeObserver(planObserver) }
    }

    nonisolated static func prepareRefresh() -> PreparedUsageRefresh {
        prepareRefresh(blockingTokenScan: false)
    }

    /// The panel never waits on the session logs: it uses the last scan and
    /// asks for a new one in the background (at most once a minute). The
    /// offscreen renderer waits, so its picture has the numbers.
    nonisolated static func spendSummary(blockingTokenScan: Bool, now: Date = Date()) -> SpendSummary? {
        let roots = TokenLogRoots.current
        let index = TokenUsageIndex.shared
        var scan = index.latest()
        if scan?.roots != roots { scan = nil }
        if scan == nil, blockingTokenScan {
            scan = index.scan(roots: roots, now: now)
        } else {
            index.refreshInBackground(roots: roots, now: now)
        }
        guard let scan else { return nil }
        let spend = SpendMemo.shared.spend(scan: scan, plans: SpendPlans.resolved(scan: scan, roots: roots), now: now)
        // Live app only: hand the CLI and agent tools a fresh copy.
        if !blockingTokenScan, !UsagePaths.isIsolatedStateDir, roots == TokenLogRoots.live(env: ProcessInfo.processInfo.environment, home: UsagePaths.home) {
            SpendSnapshotFile.writeIfNewer(spend: spend, scan: scan)
        }
        return spend
    }

    nonisolated private static func prepareRefresh(blockingTokenScan: Bool) -> PreparedUsageRefresh {
        let result = UsageStore.loadSnapshotResult()

        // Keep budget state fresh from the same snapshots the HUD displays.
        for snap in result.snapshots where snap.provider.lowercased() != "local" {
            BudgetEvaluator.evaluateAndPersist(snapshot: snap)
        }

        var loaded: [String: BudgetState] = [:]
        for snap in result.snapshots {
            if let b = BudgetStateReader.load(provider: snap.provider) {
                loaded[snap.provider.lowercased()] = b
            }
        }

        return PreparedUsageRefresh(
            loadResult: result,
            budgets: loaded,
            overrideUntil: BudgetOverride.activeUntil(),
            spend: spendSummary(blockingTokenScan: blockingTokenScan)
        )
    }

    private func applyRefresh(_ prepared: PreparedUsageRefresh) {
        snapshots = prepared.loadResult.snapshots
        lastLoadedAt = Date()
        loadError = prepared.loadResult.errors.isEmpty ? nil : prepared.loadResult.errors.joined(separator: " | ")
        budgets = prepared.budgets
        budget = prepared.budgets["claude"]
        overrideUntil = prepared.overrideUntil
        if prepared.spend != nil || spend == nil { spend = prepared.spend }
        if let active = activeRecoveryProvider,
           let snap = UsageInsights.snapshot(for: active, in: snapshots),
           !UsageInsights.laneFreshness(for: snap).needsAttention {
            activeRecoveryProvider = nil
        }
        ReadmeBadge.shared.sync(snapshots)
        publishMobileSnapshot()
        onSnapshotsChange?(snapshots)
        reconcileSetupCard()
    }

    /// `ToolDetection.detect()` probes the Keychain and filesystem. Without a
    /// stored detection summary, reuse the last live result for a few minutes
    /// instead of probing on every refresh tick; Set up and preference
    /// changes drop it.
    private func cachedDetection(now: Date = Date()) -> DetectionSummary {
        if let cached = detectionCache, now.timeIntervalSince(cached.at) < Self.detectionTTL {
            return cached.summary
        }
        let summary = ToolDetection.detect()
        detectionCache = (summary, now)
        return summary
    }

    private func reconcileSetupCard() {
        if let fixture = SetupCardModel.loadFixture(from: UsagePaths.stateDirectory) {
            setupCard = fixture
            return
        }
        if setupCard.phase == .doneWithData || setupCard.phase == .doneWithNoData {
            setupCard = setupCard.recoveringLanes(from: snapshots)
            return
        }
        if setupCard.phase == .running || setupCard.phase == .blocked {
            return
        }
        if UsagePaths.isIsolatedStateDir {
            setupCard = .hidden
            return
        }
        let summary = ProviderPreferences.detectionSummary() ?? cachedDetection()
        let installed = BackgroundRefreshService.isInstalled()
        setupCard = SetupCardModel.live(
            installed: installed,
            summary: summary,
            acknowledged: ProviderPreferences.setupCompleteAcknowledged
        )
    }
}

struct PreparedUsageRefresh: Sendable {
    var loadResult: UsageLoadResult
    var budgets: [String: BudgetState]
    var overrideUntil: Date?
    var spend: SpendSummary? = nil
}

struct UsageLoadResult: Sendable {
    var snapshots: [UsageSnapshot]
    var errors: [String]
}
