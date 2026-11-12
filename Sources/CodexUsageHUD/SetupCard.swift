import Foundation

enum SetupCardPhase: String, Equatable {
    case hidden
    case prompt
    case running
    case doneWithData
    case doneWithNoData
    /// Set up stopped before installing anything (wrong location, damaged
    /// copy). The card shows the reason and the next step in `runtimeNote`,
    /// with no lane results and no button.
    case blocked
}

enum LaneSetupStatus: Equatable {
    case pending
    case running
    case success(String)
    case failure(String)

    var isFinished: Bool {
        switch self {
        case .success, .failure: return true
        default: return false
        }
    }

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

struct LaneSetupResult: Equatable, Identifiable {
    var provider: String
    var name: String
    var status: LaneSetupStatus

    var id: String { provider }

    var line: String {
        switch status {
        case .pending, .running:
            return name
        case .success(let detail):
            return detail
        case .failure(let detail):
            return detail
        }
    }
}

struct SetupCardModel: Equatable {
    var phase: SetupCardPhase
    var foundLine: String?
    var missingLine: String?
    var runtimeNote: String?
    var lanes: [LaneSetupResult]
    var buttonTitle: String
    var buttonSubtext: String
    var completeLine: String
    var trustLine: String

    static let hidden = SetupCardModel(
        phase: .hidden,
        foundLine: nil,
        missingLine: nil,
        runtimeNote: nil,
        lanes: [],
        buttonTitle: "Set up",
        buttonSubtext: "Installs a background refresh for the tools found. About 10 seconds.",
        completeLine: "Set up complete",
        trustLine: "Readings stay on this Mac. Every number shows where it came from — official, measured, estimated or unknown."
    )

    var isVisible: Bool { phase != .hidden }

    var needsAttention: Bool { lanes.contains { $0.status.isFinished && !$0.status.isSuccess } }

    var heading: String {
        switch phase {
        case .doneWithData: return needsAttention ? "Some readings need attention" : "You’re ready"
        case .doneWithNoData: return "Waiting for your first reading"
        case .running: return "Connecting your tools…"
        case .blocked: return "Let’s finish setup"
        default: return "Set up Usage HUD"
        }
    }

    /// A successful automatic retry should clear an earlier setup warning.
    /// Keep failures that still lack a usable reading and leave installation
    /// blockers alone. A fresh reading is evidence that its producer works.
    func recoveringLanes(from snapshots: [UsageSnapshot], now: Date = Date()) -> SetupCardModel {
        guard phase == .doneWithData || phase == .doneWithNoData else { return self }
        var model = self
        model.lanes = lanes.map { lane in
            guard !lane.status.isSuccess,
                  let snapshot = UsageInsights.snapshot(for: lane.provider, in: snapshots) else { return lane }
            let refreshed = LaneSetupScoring.result(provider: lane.provider, snapshot: snapshot,
                nodeAvailable: true, pythonAvailable: true, now: now)
            return refreshed.status.isSuccess ? refreshed : lane
        }
        if model.lanes.contains(where: { $0.status.isSuccess }) { model.phase = .doneWithData }
        return model
    }

    /// No Keychain heads-up: Claude Code writes its sign-in with
    /// `/usr/bin/security`, so the in-app reader (the same tool) reads it
    /// without a prompt. A clean macOS 26 VM showed none (2026-10-03).
    static func prompt(summary: DetectionSummary) -> SetupCardModel {
        var model = hidden
        model.phase = .prompt
        model.foundLine = summary.foundLine
        model.missingLine = summary.missingLine
        model.runtimeNote = summary.runtimeNote
        model.lanes = pendingLanes(from: summary)
        return model
    }

    static func running(
        summary: DetectionSummary,
        lanes: [LaneSetupResult]? = nil
    ) -> SetupCardModel {
        var model = prompt(summary: summary)
        model.phase = .running
        model.lanes = lanes ?? pendingLanes(from: summary).map {
            LaneSetupResult(provider: $0.provider, name: $0.name, status: .running)
        }
        return model
    }

    /// Set up could not start. `reason` already ends with the next step
    /// (for example "…Move Usage HUD to Applications, then open it again.").
    static func blocked(summary: DetectionSummary, reason: String) -> SetupCardModel {
        var model = prompt(summary: summary)
        model.phase = .blocked
        model.runtimeNote = "Set up didn’t run. \(reason)"
        model.lanes = []
        return model
    }

    /// The card for a finished Set up, or the blocked card when Set up never
    /// installed anything.
    static func outcome(summary: DetectionSummary, outcome: BackgroundRefreshService.SetupOutcome, hasData: Bool) -> SetupCardModel {
        if let blocker = outcome.blocker {
            return blocked(summary: summary, reason: blocker)
        }
        return finished(summary: summary, lanes: outcome.lanes, hasData: hasData)
    }

    static func finished(summary: DetectionSummary, lanes: [LaneSetupResult], hasData: Bool) -> SetupCardModel {
        var model = prompt(summary: summary)
        model.lanes = lanes
        model.phase = hasData ? .doneWithData : .doneWithNoData
        return model
    }

    static func live(installed: Bool, summary: DetectionSummary, acknowledged: Bool) -> SetupCardModel {
        (acknowledged || installed) ? .hidden : .prompt(summary: summary)
    }

    static func loadFixture(from directory: URL) -> SetupCardModel? {
        let url = directory.appendingPathComponent("setup-card.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let fixture = try? JSONDecoder().decode(SetupCardFixture.self, from: data) else { return nil }
        return fixture.model()
    }

    private static func pendingLanes(from summary: DetectionSummary) -> [LaneSetupResult] {
        let ids = summary.foundCustomerIds.isEmpty
            ? DetectionSummary.customerOrder.map(\.id)
            : summary.foundCustomerIds
        return ids.map { id in
            LaneSetupResult(
                provider: id,
                name: UsageInsights.label(for: id),
                status: .pending
            )
        }
    }
}

struct SetupCardFixture: Codable {
    var phase: String
    var found: [String]?
    var missing: [String]?
    var runtimeNote: String?
    var lanes: [FixtureLane]?

    struct FixtureLane: Codable {
        var provider: String
        var result: String
        var ok: Bool
    }

    func model() -> SetupCardModel {
        var model = SetupCardModel.hidden
        let foundNames = found ?? []
        let missingNames = missing ?? []
        model.foundLine = foundNames.isEmpty ? nil : "Found: \(foundNames.joined(separator: ", "))"
        model.missingLine = missingNames.isEmpty ? nil : "Not found: \(missingNames.joined(separator: ", "))"
        model.runtimeNote = runtimeNote
        if let lanes {
            model.lanes = lanes.map { lane in
                LaneSetupResult(
                    provider: lane.provider,
                    name: UsageInsights.label(for: lane.provider),
                    status: lane.ok ? .success(lane.result) : .failure(lane.result)
                )
            }
        }
        switch phase.lowercased() {
        case "prompt", "ready":
            model.phase = .prompt
        case "running":
            model.phase = .running
        case "complete", "done", "done-with-data":
            model.phase = .doneWithData
        case "done-with-no-data":
            model.phase = .doneWithNoData
        case "blocked":
            model.phase = .blocked
            model.lanes = []
        default:
            model.phase = .hidden
        }
        return model
    }
}

enum LaneSetupScoring {
    static func result(
        provider: String,
        snapshot: UsageSnapshot?,
        nodeAvailable: Bool,
        pythonAvailable: Bool,
        now: Date = Date()
    ) -> LaneSetupResult {
        let name = UsageInsights.label(for: provider)
        let id = provider.lowercased()
        // Claude and Codex are read in-app when their LaunchAgents cannot
        // run (ClaudeNativeUsageReader, CodexSessionReader), so neither lane
        // needs Node.js or Python. Gemini and Grok still do.
        if nodeOnlyProviders.contains(id), !nodeAvailable {
            return LaneSetupResult(provider: id, name: name, status: .failure("\(name) ✗ needs Node.js"))
        }
        guard let snapshot else {
            let detail: String
            switch id {
            case "local":
                detail = "\(name) ✗ start Ollama"
            case "codex":
                detail = "\(name) ✗ no session yet"
            default:
                detail = "\(name) ✗ not signed in"
            }
            return LaneSetupResult(provider: id, name: name, status: .failure(detail))
        }
        // A JSON file existing is not enough: a writer-reported broken
        // health verdict or a durable no-credential status means the lane
        // is not actually working, even though it left a snapshot behind.
        if snapshot.health?.verdict?.lowercased() == "broken" {
            return LaneSetupResult(provider: id, name: name, status: .failure("\(name) ✗ broken — run diagnostics"))
        }
        let credentialStatus = (snapshot.officialUsageStatus?.status ?? snapshot.providerHealth?.status)?.lowercased()
        if credentialStatus == "token_expired" {
            return LaneSetupResult(provider: id, name: name, status: .failure("\(name) — open Claude Code once to wake its sign-in"))
        }
        if credentialStatus == "keychain_locked" {
            return LaneSetupResult(provider: id, name: name, status: .failure("\(name) — unlock Login Keychain or click Allow, then Refresh"))
        }
        if credentialStatus == "no_credential" || credentialStatus == "unauthorized" {
            return LaneSetupResult(provider: id, name: name, status: .failure("\(name) ✗ not signed in"))
        }
        if let recovery = RateLimitRecovery.make(status: snapshot.officialUsageStatus ?? snapshot.providerHealth, now: now),
           UsageInsights.laneFreshness(for: snapshot, now: now).needsAttention {
            return LaneSetupResult(provider: id, name: name,
                status: .failure("\(name) — usage rate-limited. \(recovery.detail)"))
        }
        if snapshot.health?.isWarning == true ||
            UsageInsights.sourceFreshness(for: snapshot, now: now).state == "stale" ||
            UsageInsights.windowFreshness(for: snapshot, now: now)?.state == "stale" {
            return LaneSetupResult(provider: id, name: name, status: .failure("\(name) ✗ reading is old or unavailable — refresh to try again"))
        }
        let current = UsageStore.dropExpiredWindows(snapshot, now: now)
        // A successful lane line reports the first reading's confidence when
        // the writer declared one, never when the HUD only inferred it.
        let confidenceSuffix: String
        if let declared = snapshot.confidence, !declared.isEmpty {
            confidenceSuffix = " · \(UsageInsights.confidence(snapshot).label.lowercased())"
        } else {
            confidenceSuffix = ""
        }
        for (window, period) in [(current.week, "week"), (current.currentSession, "session")] {
            if let pct = window?.usedPct, pct.isFinite, (0...100).contains(pct) {
                return LaneSetupResult(
                    provider: id,
                    name: name,
                    status: .success("\(name) ✓ \(percentText(pct)) of the \(period) used\(confidenceSuffix)")
                )
            }
        }
        // Local token counts are useful readings, but do not establish a
        // subscription provider's remaining quota.
        if id == "local", let total = snapshot.session?.total, total >= 0 {
            return LaneSetupResult(provider: id, name: name, status: .success("\(name) ✓ local token counts available\(confidenceSuffix)"))
        }
        return LaneSetupResult(provider: id, name: name, status: .failure("\(name) ✗ no usage reading yet — open the provider, then refresh"))
    }

    static func percentText(_ value: Double) -> String {
        StatusItemText.percent(value)
    }

    /// Lanes whose only producer is a Node.js LaunchAgent.
    static let nodeOnlyProviders: Set<String> = ["gemini", "grok"]

    /// Newest of the provider's snapshot files in `stateDirectory` (for
    /// Claude that includes the in-app reader's own file).
    static func loadSnapshot(provider: String, stateDirectory: URL) -> UsageSnapshot? {
        let fm = FileManager.default
        func modified(_ url: URL) -> Date {
            (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? .distantPast
        }
        let newest = UsagePaths.usageFilenames(for: provider)
            .map { stateDirectory.appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0.path) }
            .max { modified($0) < modified($1) }
        guard let newest, let data = try? Data(contentsOf: newest) else {
            // Local tokens are read in the app from Ollama's own log, never a
            // state file; ask the same reader the panel uses.
            if provider == "local", !UsagePaths.isIsolatedStateDir { return LocalModelUsageReader.loadSnapshot() }
            return nil
        }
        return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
    }

    /// `codexSessionsRoot` mirrors UsageStore's in-app Codex fallback: with
    /// no `codex-usage.json` (no Node.js, so no writer), the lane is scored
    /// from the newest rate-limit event in the Codex session logs.
    static func score(
        providers: [String],
        stateDirectory: URL,
        nodeAvailable: Bool,
        pythonAvailable: Bool,
        codexSessionsRoot: URL? = nil
    ) -> [LaneSetupResult] {
        providers.map { provider in
            var snapshot = loadSnapshot(provider: provider, stateDirectory: stateDirectory)
            if snapshot == nil, provider.lowercased() == "codex", let codexSessionsRoot {
                snapshot = CodexSessionReader.loadSnapshot(fromSessionsRoot: codexSessionsRoot)
            }
            return result(
                provider: provider,
                snapshot: snapshot,
                nodeAvailable: nodeAvailable,
                pythonAvailable: pythonAvailable
            )
        }
    }

    static func hasUsableData(_ results: [LaneSetupResult]) -> Bool {
        results.contains { $0.status.isSuccess }
    }
}
