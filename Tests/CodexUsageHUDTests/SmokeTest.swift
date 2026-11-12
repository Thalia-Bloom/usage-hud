import XCTest
@testable import CodexUsageHUD

final class SmokeTest: XCTestCase {
    func testResetPingRequiresFreshConfirmedRolloverAndDoesNotRepeat() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(60)
        func snapshot(_ used: Double, _ captured: Date, _ nextReset: Date) -> UsageSnapshot {
            UsageSnapshot(provider: "claude", capturedAt: captured.ISO8601Format(),
                          currentSession: .init(usedPct: used, resetAt: nextReset.ISO8601Format()),
                          contributors: [], skills: [], subagents: [])
        }
        var tracker = ResetPingTracker()
        let spent = snapshot(100, now, reset)
        XCTAssertTrue(tracker.observe([spent], enabled: ["claude"], snoozed: false, now: now).isEmpty)
        XCTAssertEqual(tracker.watches.count, 1)
        // A restart preserves the watch. Passing the deadline or losing data is not a reset confirmation.
        tracker = try JSONDecoder().decode(ResetPingTracker.self, from: JSONEncoder().encode(tracker))
        let after = reset.addingTimeInterval(5)
        XCTAssertTrue(tracker.observe([UsageStore.dropExpiredWindows(spent, now: after)], enabled: ["claude"], snoozed: false, now: after).isEmpty)
        XCTAssertTrue(tracker.observe([], enabled: ["claude"], snoozed: false, now: after).isEmpty)
        let stale = snapshot(0, now.addingTimeInterval(-3600), reset.addingTimeInterval(18000))
        XCTAssertTrue(tracker.observe([stale], enabled: ["claude"], snoozed: false, now: after).isEmpty)
        let fresh = snapshot(3, after, reset.addingTimeInterval(18000))
        XCTAssertEqual(tracker.observe([fresh], enabled: ["claude"], snoozed: false, now: after).count, 1)
        tracker = try JSONDecoder().decode(ResetPingTracker.self, from: JSONEncoder().encode(tracker))
        XCTAssertTrue(tracker.observe([fresh], enabled: ["claude"], snoozed: false, now: after).isEmpty)
        XCTAssertEqual(tracker.history.count, 1)
    }

    func testResetPingSnoozeAndProviderOptOut() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(60)
        var snapshot = UsageSnapshot(provider: "codex", capturedAt: now.ISO8601Format(),
                                     week: .init(usedPct: 100, resetAt: reset.ISO8601Format()),
                                     contributors: [], skills: [], subagents: [])
        var tracker = ResetPingTracker()
        XCTAssertTrue(tracker.observe([snapshot], enabled: [], snoozed: false, now: now).isEmpty)
        XCTAssertTrue(tracker.watches.isEmpty)
        _ = tracker.observe([snapshot], enabled: ["codex"], snoozed: false, now: now)
        let after = reset.addingTimeInterval(5)
        snapshot.capturedAt = after.ISO8601Format()
        snapshot.week = .init(usedPct: 0, resetAt: reset.addingTimeInterval(604800).ISO8601Format())
        XCTAssertTrue(tracker.observe([snapshot], enabled: ["codex"], snoozed: true, now: after).isEmpty)
        XCTAssertEqual(tracker.watches.count, 1)
        XCTAssertEqual(tracker.observe([snapshot], enabled: ["codex"], snoozed: false, now: after).count, 1)
        var unexhausted = ResetPingTracker()
        XCTAssertTrue(unexhausted.observe([snapshot], enabled: ["codex"], snoozed: false, now: after).isEmpty)
        XCTAssertTrue(unexhausted.watches.isEmpty)
        _ = tracker.observe([], enabled: [], snoozed: false, now: after)
        XCTAssertTrue(tracker.watches.isEmpty)
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testUsageStoreHasProviders() {
        XCTAssertEqual(UsageStore.providers, ["codex", "claude", "gemini", "grok", "local"])
    }

    func testVisibleProvidersIncludeEmptyCustomerLanes() {
        XCTAssertEqual(
            UsageInsights.visibleProviderOrder(snapshots: [], selection: .all),
            ["codex", "claude", "gemini", "grok", "local"]
        )
    }

    func testMissingSnapshotsAreNotReportedStale() {
        XCTAssertEqual(UsageInsights.staleSourceProviders([]), [])
        XCTAssertEqual(UsageInsights.staleWindowProviders([]), [])
    }

    /// The "Claude: clear to build" hero must only claim freshness the
    /// reading actually has: missing or older-than-window snapshots are
    /// never fresh, and a snapshot right at the window is still fresh.
    func testIsReadingFreshGatesOnCapturedAge() throws {
        let now = try XCTUnwrap(UsageInsights.parseDate("2026-06-07T17:00:00Z"))
        XCTAssertFalse(UsageInsights.isReadingFresh(nil, within: 15 * 60, now: now))

        let fresh = UsageSnapshot(
            provider: "claude",
            capturedAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-5 * 60)),
            contributors: [], skills: [], subagents: []
        )
        XCTAssertTrue(UsageInsights.isReadingFresh(fresh, within: 15 * 60, now: now))

        let stale = UsageSnapshot(
            provider: "claude",
            capturedAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-16 * 60)),
            contributors: [], skills: [], subagents: []
        )
        XCTAssertFalse(UsageInsights.isReadingFresh(stale, within: 15 * 60, now: now))
    }

    /// A lane whose snapshot declares an observation/manual source kind is
    /// read by hand: a week-old reading must never count as a stale
    /// source/window, since neither drives the header chip or the
    /// manual-refresh footer for a lane that never auto-refreshes.
    func testManualObservationLaneNeverCountsAsStale() throws {
        let now = try XCTUnwrap(UsageInsights.parseDate("2026-06-07T17:00:00Z"))
        let weekOldStamp = try XCTUnwrap(UsageInsights.parseDate("2026-05-30T17:00:00Z"))
        let manual = UsageSnapshot(
            provider: "grok",
            sourceKind: "native_ui_observation",
            capturedAt: ISO8601DateFormatter().string(from: weekOldStamp),
            week: UsageSnapshot.WindowMetric(label: "Grok week", usedPct: 40),
            contributors: [],
            skills: [],
            subagents: []
        )
        XCTAssertTrue(UsageInsights.isManualObservationLane("grok", snapshots: [manual]))
        XCTAssertFalse(UsageInsights.isManualObservationLane("grok", snapshots: []))
        XCTAssertFalse(UsageInsights.staleSourceProviders([manual], now: now).contains("Grok"))
        XCTAssertFalse(UsageInsights.staleWindowProviders([manual], now: now).contains("Grok"))
    }

    func testEmptyLaneCopyIsPlainEnglishAndNameFree() {
        XCTAssertEqual(
            EmptyLaneCopy.line(for: "codex", nodeAvailable: true, pythonAvailable: true),
            "Run one Codex session, then Refresh"
        )
        XCTAssertEqual(
            EmptyLaneCopy.line(for: "claude", nodeAvailable: true, pythonAvailable: true),
            "Sign in to Claude Code, then Refresh"
        )
        XCTAssertEqual(
            EmptyLaneCopy.line(for: "gemini", nodeAvailable: true, pythonAvailable: true),
            "Sign in to Antigravity (agy), then Refresh"
        )
        XCTAssertEqual(
            EmptyLaneCopy.line(for: "grok", nodeAvailable: true, pythonAvailable: true),
            "Sign in to Grok, then Refresh"
        )
        XCTAssertEqual(
            EmptyLaneCopy.line(for: "local", nodeAvailable: true, pythonAvailable: true),
            "Start Ollama"
        )
        // Claude and Codex are read in-app without Node.js or Python.
        XCTAssertEqual(
            EmptyLaneCopy.line(for: "codex", nodeAvailable: false, pythonAvailable: false),
            "Run one Codex session, then Refresh"
        )
        XCTAssertEqual(
            EmptyLaneCopy.line(for: "claude", nodeAvailable: false, pythonAvailable: false),
            "Sign in to Claude Code, then Refresh"
        )
        XCTAssertEqual(
            EmptyLaneCopy.line(for: "gemini", nodeAvailable: false, pythonAvailable: true),
            "Gemini needs Node.js. Install it from nodejs.org."
        )
        XCTAssertEqual(
            EmptyLaneCopy.line(for: "grok", nodeAvailable: false, pythonAvailable: true),
            "Grok needs Node.js. Install it from nodejs.org."
        )
        for provider in ["codex", "claude", "gemini", "grok", "local"] {
            let line = EmptyLaneCopy.line(for: provider, nodeAvailable: true, pythonAvailable: true)
            XCTAssertFalse(line.contains("Bloom"))
            XCTAssertFalse(line.contains("Thalia"))
        }
    }

    func testAppInfoDeclaresVersion() {
        XCTAssertEqual(AppInfo.marketingVersion, "1.3.6")
        XCTAssertEqual(AppInfo.buildNumber, "17")
        XCTAssertEqual(AppInfo.versionLine, "Usage HUD 1.3.6")
        XCTAssertEqual(AppInfo.legalName, "Thalia Bloom")
        XCTAssertEqual(AppInfo.supportLine, "Updates and support: https://hud.thaliabloom.com/support/")
    }

    func testIsolatedStateDirIgnoresCanonicalHomePaths() {
        let home = URL(fileURLWithPath: "/Users/example")
        XCTAssertFalse(UsagePaths.isIsolatedOverride("/Users/example/.codex-usage-hud", home: home))
        XCTAssertFalse(UsagePaths.isIsolatedOverride("~/.codex-usage-hud", home: home))
        XCTAssertTrue(UsagePaths.isIsolatedOverride("/Users/example/.other-state", home: home))
        XCTAssertTrue(UsagePaths.isIsolatedOverride("/tmp/empty-hud-state", home: home))
    }

    func testOnlyTheCanonicalStateDirectoryIsRead() {
        XCTAssertEqual(UsagePaths.stateDirectoriesForRead, [UsagePaths.stateDirectory])
        let candidates = UsagePaths.providerUsageCandidates("grok")
        XCTAssertEqual(candidates.first, UsagePaths.stateDirectory.appendingPathComponent("grok-usage.json"))
        XCTAssertTrue(candidates.count <= 2, "state dir plus at most the Application Support state folder")
        for url in candidates {
            XCTAssertFalse(url.path.contains("/.bloom-usage/"), url.path)
            XCTAssertFalse(url.path.contains("Bloom Usage HUD"), url.path)
        }
    }

    func testProviderPreferencesKeepConnectionAndVisibilitySeparate() throws {
        // This checks the UserDefaults path, which only applies to the canonical state dir. When the suite runs with
        // CODEX_USAGE_HUD_STATE_DIR pointed at a throwaway folder (so tests never touch a real ~/.codex-usage-hud),
        // selection reads the isolated file instead; clear the override for this test and restore it after.
        let savedStateDir = ProcessInfo.processInfo.environment["CODEX_USAGE_HUD_STATE_DIR"]
        unsetenv("CODEX_USAGE_HUD_STATE_DIR")
        defer { if let savedStateDir { setenv("CODEX_USAGE_HUD_STATE_DIR", savedStateDir, 1) } }
        let suite = "UsageHUDTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(ProviderPreferences.isConnected("claude", defaults: defaults))
        XCTAssertTrue(ProviderPreferences.isShown("claude", defaults: defaults))
        defaults.set(false, forKey: ProviderPreferences.connectedKey(for: "claude"))
        defaults.set(true, forKey: ProviderPreferences.shownKey(for: "claude"))

        let selection = ProviderPreferences.selection(defaults: defaults)
        XCTAssertFalse(selection.includes("claude"))
        XCTAssertTrue(selection.shown.contains("claude"))
    }

    func testHiddenProviderDoesNotAppearEvenWhenItHasData() {
        let claude = UsageSnapshot(provider: "claude")
        let selection = ProviderSelection(
            connected: Set(ProviderCatalog.ids),
            shown: Set(ProviderCatalog.ids.filter { $0 != "claude" })
        )

        XCTAssertFalse(
            UsageInsights.visibleProviderOrder(snapshots: [claude], selection: selection).contains("claude")
        )
    }

    func testOllamaLogURLsPickServerLogsOnly() throws {
        let root = TestTemporaryDirectory.root
            .appendingPathComponent("hud-local-logs-\(UUID().uuidString)")
        let primary = root.appendingPathComponent("ollama-logs")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        try "x".write(to: primary.appendingPathComponent("server.log"), atomically: true, encoding: .utf8)
        try "x".write(to: primary.appendingPathComponent("server-1.log"), atomically: true, encoding: .utf8)
        try "x".write(to: primary.appendingPathComponent("app.log"), atomically: true, encoding: .utf8)

        let urls = LocalModelUsageReader.logURLs(in: primary)
        XCTAssertEqual(urls.map { $0.resolvingSymlinksInPath().path }, [
            primary.appendingPathComponent("server-1.log").resolvingSymlinksInPath().path,
            primary.appendingPathComponent("server.log").resolvingSymlinksInPath().path,
        ])
        XCTAssertTrue(LocalModelUsageReader.logURLs(in: root.appendingPathComponent("missing")).isEmpty)
    }

    func testOllamaLogParserCountsPromptGeneratedTodayAndModels() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-01T20:00:00Z"))
        let log = """
        time=2026-08-01T19:00:00Z level=INFO source=images.go msg="template selection" model=registry.ollama.ai/library/gemma3:4b selected=go_template
        slot print_timing: id 0 | task 7 | prompt eval time = 10 ms / 120 tokens (12 tokens per second)
        slot print_timing: id 0 | task 7 | eval time = 10 ms / 30 tokens (3 tokens per second)
        [GIN] 2026/08/01 - 19:00:01 | 200 | 20ms | 127.0.0.1 | POST "/v1/chat/completions"
        """

        let summary = try XCTUnwrap(LocalModelUsageReader.parse(logs: [log], now: now, calendar: calendar))
        XCTAssertEqual(summary.promptTokens, 120)
        XCTAssertEqual(summary.generatedTokens, 30)
        XCTAssertEqual(summary.totalTokens, 150)
        XCTAssertEqual(summary.todayTokens, 150)
        XCTAssertEqual(summary.weekTokens, 150)
        XCTAssertEqual(summary.requestCount, 1)
        XCTAssertEqual(summary.modelTokens["gemma3:4b"], 150)
    }

    func testBudgetStateReaderReturnsNilForMissingProvider() {
        XCTAssertNil(BudgetStateReader.load(provider: "nonexistent-provider"))
    }

    func testBudgetOverrideSetClearRoundtrip() {
        BudgetOverride.clear()
        XCTAssertNil(BudgetOverride.activeUntil())
        BudgetOverride.setUntil(Date().addingTimeInterval(60))
        XCTAssertNotNil(BudgetOverride.activeUntil())
        BudgetOverride.clear()
        XCTAssertNil(BudgetOverride.activeUntil())
    }

    func testManualRefreshDoesNotTreatSharedLockAsCompletion() {
        XCTAssertEqual(ManualRefreshService.busyExitStatus, 75)
        let feedback = ManualRefreshFeedback.finished(.alreadyRunning, before: [], after: [], providers: [])
        XCTAssertNil(feedback.checkedAt)
        XCTAssertEqual(feedback.title, "Already refreshing")
    }

    func testFallbackHeadroomModeMatchesDefaultWeeklyPolicy() {
        XCTAssertEqual(BudgetEvaluator.fallbackModeFromHeadroom(0), "freeze")
        XCTAssertEqual(BudgetEvaluator.fallbackModeFromHeadroom(8), "red")
        XCTAssertEqual(BudgetEvaluator.fallbackModeFromHeadroom(10), "orange")
        XCTAssertEqual(BudgetEvaluator.fallbackModeFromHeadroom(19), "orange")
        XCTAssertEqual(BudgetEvaluator.fallbackModeFromHeadroom(20), "yellow")
        XCTAssertEqual(BudgetEvaluator.fallbackModeFromHeadroom(40), "green")
    }

    func testCodexExtendedSessionMetricsDecode() throws {
        let json = """
        {
          "schemaVersion": 1,
          "provider": "codex",
          "updatedAt": "2026-05-04T03:23:21.015Z",
          "eventAt": "2026-05-04T03:23:21.015Z",
          "capturedAt": "2026-05-12T20:28:24.513Z",
          "session": {
            "input": 1200,
            "output": 300,
            "cacheRead": 700,
            "reasoningOutput": 90,
            "total": 1500,
            "lastInput": 200,
            "lastOutput": 40,
            "lastCacheRead": 100,
            "lastReasoningOutput": 20,
            "lastTotal": 240,
            "contextWindow": 258400
          },
          "contributors": [],
          "skills": [],
          "subagents": []
        }
        """

        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.capturedAt, "2026-05-12T20:28:24.513Z")
        XCTAssertEqual(snapshot.eventAt, "2026-05-04T03:23:21.015Z")
        XCTAssertEqual(snapshot.session?.reasoningOutput, 90)
        XCTAssertEqual(snapshot.session?.lastTotal, 240)
        XCTAssertEqual(snapshot.session?.contextWindow, 258400)
        let session = try XCTUnwrap(snapshot.session)
        XCTAssertLessThan(try XCTUnwrap(UsageInsights.contextTurnUsagePercent(session)), 0.1)
    }

    func testUsageStorePreservesExpiredWindowAsIdleLastKnown() throws {
        let now = try XCTUnwrap(UsageInsights.parseDate("2026-06-30T17:00:00Z"))
        let snapshot = UsageSnapshot(
            provider: "claude",
            currentSession: UsageSnapshot.WindowMetric(
                label: "Current session",
                usedPct: 91,
                resetLabel: "Jun 30 16:00",
                resetAt: "2026-06-30T16:00:00Z"
            ),
            week: UsageSnapshot.WindowMetric(
                label: "Current week",
                usedPct: 50,
                resetLabel: "Jul 1 17:00",
                resetAt: "2026-07-01T17:00:00Z"
            ),
            contributors: [],
            skills: [],
            subagents: []
        )

        let cleaned = UsageStore.dropExpiredWindows(snapshot, now: now)
        XCTAssertEqual(cleaned.currentSession?.state, "expired")
        XCTAssertNil(cleaned.currentSession?.usedPct)
        XCTAssertEqual(cleaned.currentSession?.lastKnownUsedPct, 91)
        XCTAssertEqual(cleaned.currentSession?.displayUsedPct, 91)
        XCTAssertEqual(cleaned.week?.usedPct, 50)
    }

    func testSchemaV2WindowsAreAuthoritativeAndSelectProviderPool() throws {
        let json = """
        {
          "schemaVersion": 2,
          "provider": "gemini",
          "currentSession": { "label": "legacy 5h", "usedPct": 99 },
          "week": { "label": "legacy week", "usedPct": 98 },
          "windows": [
            { "id": "gemini-weekly", "label": "Gemini weekly", "usedPct": 12,
              "resetAt": "2026-07-19T00:44:41Z", "eventAt": "2026-07-13T02:14:43Z", "state": "live" },
            { "id": "gemini-5h", "label": "Gemini 5h", "usedPct": 54,
              "resetAt": "2026-07-13T05:50:07Z", "eventAt": "2026-07-13T02:14:43Z", "state": "expired" },
            { "id": "3p-weekly", "label": "Claude/GPT (agy) weekly", "usedPct": 88,
              "resetAt": "2026-07-19T00:42:59Z", "eventAt": "2026-07-13T02:14:43Z", "state": "live" }
          ],
          "contributors": [], "skills": [], "subagents": []
        }
        """

        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.windows.count, 3)
        XCTAssertEqual(snapshot.week?.id, "gemini-weekly")
        XCTAssertEqual(snapshot.week?.usedPct, 12)
        XCTAssertEqual(snapshot.currentSession?.id, "gemini-5h")
        XCTAssertEqual(snapshot.currentSession?.state, "expired")
        XCTAssertNil(snapshot.currentSession?.usedPct)
        XCTAssertEqual(snapshot.currentSession?.lastKnownUsedPct, 54)
    }

    func testSchemaV1WindowFieldsRemainFallbackWithoutWindowsArray() throws {
        let json = """
        {
          "schemaVersion": 1,
          "provider": "claude",
          "currentSession": { "label": "Current session", "usedPct": 21 },
          "week": { "label": "Current week", "usedPct": 34 },
          "contributors": [], "skills": [], "subagents": []
        }
        """

        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertTrue(snapshot.windows.isEmpty)
        XCTAssertEqual(snapshot.currentSession?.usedPct, 21)
        XCTAssertEqual(snapshot.week?.usedPct, 34)
    }

    func testProviderHealthDecodesClaudeRateLimitStatus() throws {
        let json = """
        {
          "schemaVersion": 1,
          "provider": "claude",
          "providerHealth": {
            "status": "rate_limited",
            "message": "Claude Code official /usage endpoint is rate-limited.",
            "updatedAt": "2026-06-24T15:16:56Z",
            "retryAt": "2026-06-24T15:46:56Z"
          },
          "contributors": [],
          "skills": [],
          "subagents": []
        }
        """

        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.providerHealth?.status, "rate_limited")
        XCTAssertTrue(snapshot.providerHealth?.isWarning == true)
    }

    func testProviderHealthRejectsOkStatusWithKilledExitCode() throws {
        let json = """
        {
          "schemaVersion": 1,
          "provider": "claude",
          "officialUsageStatus": {
            "status": "ok",
            "message": "Parsed.",
            "exitCode": -9,
            "updatedAt": "2026-07-13T02:04:45Z"
          },
          "contributors": [], "skills": [], "subagents": []
        }
        """

        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.officialUsageStatus?.exitCode, -9)
        XCTAssertTrue(snapshot.officialUsageStatus?.isWarning == true)
    }

    func testHeaderIncludesTransitionalHealthWarningsButClearsOlderProviderWarning() throws {
        let cleared = try JSONDecoder().decode(UsageSnapshot.self, from: Data("""
        {
          "provider": "claude",
          "providerHealth": {"status":"unparsed","updatedAt":"2026-07-12T10:00:00Z"},
          "officialUsageStatus": {"status":"ok","exitCode":0,"updatedAt":"2026-07-12T11:00:00Z"}
        }
        """.utf8))
        XCTAssertFalse(headerHasHealthWarning(cleared))

        let killed = try JSONDecoder().decode(UsageSnapshot.self, from: Data("""
        {
          "provider": "claude",
          "officialUsageStatus": {"status":"ok","exitCode":-9,"updatedAt":"2026-07-12T11:00:00Z"}
        }
        """.utf8))
        XCTAssertTrue(headerHasHealthWarning(killed))

        let providerWarning = try JSONDecoder().decode(UsageSnapshot.self, from: Data("""
        {"provider":"claude","providerHealth":{"status":"rate_limited","updatedAt":"2026-07-12T11:00:00Z"}}
        """.utf8))
        XCTAssertTrue(headerHasHealthWarning(providerWarning))

        let laneWarning = try JSONDecoder().decode(UsageSnapshot.self, from: Data("""
        {"provider":"gemini","health":{"verdict":"stale","checkedAt":"2026-07-12T11:00:00Z"}}
        """.utf8))
        XCTAssertTrue(headerHasHealthWarning(laneWarning))
    }

    // A stale official refetch (expired token overnight, endpoint offline)
    // must not flag the header while the statusline tap is still feeding
    // live 5h/week windows, since the pipeline is provably working. The
    // detail card's own health line still shows the failed refetch; only
    // the header pill is quieted.
    func testHeaderIgnoresOfficialWarningWhenWindowsAreLive() throws {
        let iso = ISO8601DateFormatter()
        let snapshot = UsageSnapshot(
            provider: "claude",
            week: UsageSnapshot.WindowMetric(
                label: "Current week",
                usedPct: 32,
                resetLabel: "Sep 9 4 PM",
                eventAt: iso.string(from: Date().addingTimeInterval(-60))
            ),
            contributors: [], skills: [], subagents: [],
            officialUsageStatus: UsageSnapshot.ProviderHealth(
                status: "offline",
                updatedAt: iso.string(from: Date())
            )
        )

        XCTAssertEqual(UsageInsights.windowFreshness(for: snapshot)?.rank, 0)
        XCTAssertFalse(headerHasHealthWarning(snapshot))
    }

    // A revoked or missing credential is a durable failure that needs a
    // human, even while the tap keeps feeding live 5h/week windows. The
    // live-window bypass above must not hide it.
    func testHeaderStillWarnsOnRevokedTokenWhileWindowsLive() throws {
        let iso = ISO8601DateFormatter()
        let snapshot = UsageSnapshot(
            provider: "claude",
            week: UsageSnapshot.WindowMetric(
                label: "Current week",
                usedPct: 32,
                resetLabel: "Sep 9 4 PM",
                eventAt: iso.string(from: Date().addingTimeInterval(-60))
            ),
            contributors: [], skills: [], subagents: [],
            officialUsageStatus: UsageSnapshot.ProviderHealth(
                status: "unauthorized",
                updatedAt: iso.string(from: Date())
            )
        )

        XCTAssertEqual(UsageInsights.windowFreshness(for: snapshot)?.rank, 0)
        XCTAssertTrue(headerHasHealthWarning(snapshot))
    }

    // Once the tap-fed window ages past "live" (here, 2 hours), a failed
    // official refetch goes back to flagging the header as before.
    func testHeaderStillWarnsOnOfficialFailureOnceWindowsAgeOut() throws {
        let iso = ISO8601DateFormatter()
        let snapshot = UsageSnapshot(
            provider: "claude",
            week: UsageSnapshot.WindowMetric(
                label: "Current week",
                usedPct: 32,
                resetLabel: "Sep 9 4 PM",
                eventAt: iso.string(from: Date().addingTimeInterval(-2 * 60 * 60))
            ),
            contributors: [], skills: [], subagents: [],
            officialUsageStatus: UsageSnapshot.ProviderHealth(
                status: "offline",
                updatedAt: iso.string(from: Date())
            )
        )

        XCTAssertNotEqual(UsageInsights.windowFreshness(for: snapshot)?.rank, 0)
        XCTAssertTrue(headerHasHealthWarning(snapshot))
    }

    // A writer-reported lane health warning always wins, even over live
    // windows, since schema-v2 health is the strongest signal in the pipeline.
    func testHeaderLaneHealthWarningWinsOverLiveWindows() throws {
        let iso = ISO8601DateFormatter()
        let snapshot = UsageSnapshot(
            provider: "claude",
            week: UsageSnapshot.WindowMetric(
                label: "Current week",
                usedPct: 32,
                resetLabel: "Sep 9 4 PM",
                eventAt: iso.string(from: Date().addingTimeInterval(-60))
            ),
            contributors: [], skills: [], subagents: [],
            health: UsageSnapshot.LaneHealth(
                verdict: "degraded",
                reason: "writer crash",
                checkedAt: iso.string(from: Date())
            )
        )

        XCTAssertEqual(UsageInsights.windowFreshness(for: snapshot)?.rank, 0)
        XCTAssertTrue(headerHasHealthWarning(snapshot))
    }

    func testSourceConfidencePrefersDeclaredConfidence() throws {
        let snapshot = UsageSnapshot(
            provider: "codex",
            source: "codex session writer",
            sourceKind: "local_session_log",
            confidence: "high",
            confidenceNote: "Local event source.",
            updatedAt: "2026-05-12T20:28:24Z",
            contributors: [],
            skills: [],
            subagents: []
        )

        let confidence = UsageInsights.confidence(snapshot)
        XCTAssertEqual(confidence.level, "high")
        XCTAssertEqual(confidence.label, "High")
        XCTAssertEqual(confidence.detail, "Local event source.")
        XCTAssertEqual(UsageInsights.sourceQuality(snapshot), "local session log")
    }

    func testCodexSessionReaderPrefersGlobalLimitOverModelSpecificLimit() throws {
        let global = """
        {"timestamp":"2026-05-03T01:35:49.748Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":254755283,"cached_input_tokens":245565568,"output_tokens":609248,"reasoning_output_tokens":155457,"total_tokens":255364531},"last_token_usage":{"input_tokens":218605,"cached_input_tokens":204160,"output_tokens":48,"reasoning_output_tokens":9,"total_tokens":218653},"model_context_window":258400},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":2.0,"window_minutes":300,"resets_at":1893456000},"secondary":{"used_percent":80.0,"window_minutes":10080,"resets_at":1894060800},"credits":{"has_credits":false,"unlimited":false,"balance":null},"plan_type":"pro","rate_limit_reached_type":null}}}
        """
        let modelSpecific = """
        {"timestamp":"2026-05-03T01:35:49.756Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":254755283,"cached_input_tokens":245565568,"output_tokens":609248,"reasoning_output_tokens":155457,"total_tokens":255364531},"last_token_usage":{"input_tokens":218605,"cached_input_tokens":204160,"output_tokens":48,"reasoning_output_tokens":9,"total_tokens":218653},"model_context_window":258400},"rate_limits":{"limit_id":"codex_bengalfox","limit_name":"GPT-5.3-Codex-Spark","primary":{"used_percent":0.0,"window_minutes":300,"resets_at":1893456000},"secondary":{"used_percent":0.0,"window_minutes":10080,"resets_at":1894060800},"credits":{"has_credits":false,"unlimited":false,"balance":null},"plan_type":"pro","rate_limit_reached_type":null}}}
        """

        let snapshot = try XCTUnwrap(CodexSessionReader.snapshot(fromTail: [global, modelSpecific].joined(separator: "\n"), path: "/tmp/session.jsonl"))
        XCTAssertEqual(snapshot.currentSession?.usedPct, 2.0)
        XCTAssertEqual(snapshot.week?.usedPct, 80.0)
        XCTAssertEqual(snapshot.extraUsage, "pro / codex")
        XCTAssertEqual(snapshot.session?.total, 255_364_531)
    }

    func testCodexSessionFallbackClassifiesWindowsByDurationAndLabel() throws {
        let byDuration = """
        {"timestamp":"2026-07-12T11:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","primary":{"used_percent":11.0,"window_minutes":10080,"resets_at":1894060800},"secondary":{"used_percent":42.0,"window_minutes":300,"resets_at":1893456000},"plan_type":"pro"}}}
        """
        let durationSnapshot = try XCTUnwrap(CodexSessionReader.snapshot(fromTail: byDuration, path: "/tmp/duration.jsonl"))
        XCTAssertEqual(durationSnapshot.currentSession?.usedPct, 42)
        XCTAssertEqual(durationSnapshot.week?.usedPct, 11)

        let byLabel = """
        {"timestamp":"2026-07-12T11:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","primary":{"used_percent":17.0,"name":"Current week","resets_at":1894060800},"secondary":{"used_percent":33.0,"label":"Current session","resets_at":1893456000},"plan_type":"pro"}}}
        """
        let labelSnapshot = try XCTUnwrap(CodexSessionReader.snapshot(fromTail: byLabel, path: "/tmp/label.jsonl"))
        XCTAssertEqual(labelSnapshot.currentSession?.usedPct, 33)
        XCTAssertEqual(labelSnapshot.week?.usedPct, 17)
    }

    func testCodexSessionFixturePrefersGlobalLimit() throws {
        let url = repoRoot.appendingPathComponent("fixtures/codex-session-global-preferred.jsonl")
        let tail = try String(contentsOf: url, encoding: .utf8)
        let snapshot = try XCTUnwrap(CodexSessionReader.snapshot(fromTail: tail, path: url.path))

        XCTAssertEqual(snapshot.sourceKind, "local_session_log")
        XCTAssertEqual(snapshot.confidence, "high")
        XCTAssertEqual(snapshot.currentSession?.usedPct, 2.0)
        XCTAssertEqual(snapshot.week?.usedPct, 80.0)
        XCTAssertEqual(snapshot.extraUsage, "pro / codex")
    }

    func testCodexSessionReaderPrefersNewestEventAcrossFiles() throws {
        let fm = FileManager.default
        let root = TestTemporaryDirectory.root.appendingPathComponent("codex-session-reader-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let staleEventInNewestFile = """
        {"timestamp":"2026-06-13T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","primary":{"used_percent":10.0,"window_minutes":300,"resets_at":1893456000},"secondary":{"used_percent":10.0,"window_minutes":10080,"resets_at":1894060800},"plan_type":"pro"}}}
        """
        let freshEventInOlderFile = """
        {"timestamp":"2026-06-13T10:04:00Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","primary":{"used_percent":64.0,"window_minutes":300,"resets_at":1893456000},"secondary":{"used_percent":82.0,"window_minutes":10080,"resets_at":1894060800},"plan_type":"pro"}}}
        """

        let newestByMtime = root.appendingPathComponent("A.jsonl")
        let olderByMtime = root.appendingPathComponent("B.jsonl")
        try staleEventInNewestFile.write(to: newestByMtime, atomically: true, encoding: .utf8)
        try freshEventInOlderFile.write(to: olderByMtime, atomically: true, encoding: .utf8)

        let iso = ISO8601DateFormatter()
        try fm.setAttributes([.modificationDate: try XCTUnwrap(iso.date(from: "2026-06-13T10:05:00Z"))], ofItemAtPath: newestByMtime.path)
        try fm.setAttributes([.modificationDate: try XCTUnwrap(iso.date(from: "2026-06-13T10:04:30Z"))], ofItemAtPath: olderByMtime.path)

        let snapshot = try XCTUnwrap(CodexSessionReader.loadSnapshot(fromSessionsRoot: root))
        XCTAssertEqual(snapshot.currentSession?.usedPct, 64.0)
        XCTAssertEqual(snapshot.week?.usedPct, 82.0)
        XCTAssertEqual(
            URL(fileURLWithPath: try XCTUnwrap(snapshot.sourcePath)).resolvingSymlinksInPath().path,
            olderByMtime.resolvingSymlinksInPath().path
        )
    }

    func testCodexSessionReaderSurvivesTailStartingInsideUTF8Sequence() throws {
        let fm = FileManager.default
        let root = TestTemporaryDirectory.root.appendingPathComponent("codex-session-reader-utf8-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let event = """
        {"timestamp":"2026-06-13T10:06:00Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","primary":{"used_percent":44.0,"window_minutes":300,"resets_at":1893456000},"secondary":{"used_percent":88.0,"window_minutes":10080,"resets_at":1894060800},"plan_type":"pro"}}}
        """
        var data = Data([0x41, 0xF0, 0x9F, 0x98, 0x80, 0x0A])
        data.append(Data((event + "\n").utf8))
        data.append(Data(repeating: 0x78, count: max(0, (2 * 1024 * 1024 + 2) - data.count)))

        let url = root.appendingPathComponent("tail.jsonl")
        try data.write(to: url)

        let snapshot = try XCTUnwrap(CodexSessionReader.loadSnapshot(fromSessionsRoot: root))
        XCTAssertEqual(snapshot.currentSession?.usedPct, 44.0)
        XCTAssertEqual(snapshot.week?.usedPct, 88.0)
    }

    func testCodexSessionReaderPreservesExpiredRateWindowsAsIdle() throws {
        let expired = """
        {"timestamp":"2026-04-11T15:38:55.000Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","primary":{"used_percent":3.0,"window_minutes":300,"resets_at":1776000000},"secondary":{"used_percent":5.0,"window_minutes":10080,"resets_at":1776100000},"plan_type":"pro"}}}
        """

        let snapshot = try XCTUnwrap(CodexSessionReader.snapshot(fromTail: expired, path: "/tmp/expired.jsonl"))
        XCTAssertEqual(snapshot.currentSession?.state, "expired")
        XCTAssertNil(snapshot.currentSession?.usedPct)
        XCTAssertEqual(snapshot.currentSession?.lastKnownUsedPct, 3)
        XCTAssertEqual(snapshot.week?.state, "expired")
        XCTAssertNil(snapshot.week?.usedPct)
        XCTAssertEqual(snapshot.week?.lastKnownUsedPct, 5)
    }

    func testCreditPoolPolicyMapsProvider() throws {
        let policy: [String: Any] = [
            "providerCreditPools": ["codex": "teamCredits"],
            "creditPools": [
                "teamCredits": [
                    "displayName": "Team credits",
                    "remainingCreditsManual": 2500,
                    "startingCredits": 5000,
                    "creditsPerUSD": 25,
                    "status": "active"
                ]
            ]
        ]

        let pool = try XCTUnwrap(CreditPoolReader.parse(provider: "codex", policy: policy))
        XCTAssertEqual(pool.displayName, "Team credits")
        XCTAssertEqual(pool.remainingPercent, 50)
        XCTAssertEqual(pool.estimatedUSDRemaining, 100)
    }

    func testSourceFreshnessMarksOldSnapshotsStale() throws {
        let now = try XCTUnwrap(UsageInsights.parseDate("2026-05-10T12:00:00Z"))
        let snapshot = UsageSnapshot(
            provider: "gemini",
            updatedAt: "2026-05-08T12:00:00Z",
            contributors: [],
            skills: [],
            subagents: []
        )

        XCTAssertEqual(UsageInsights.sourceFreshness(for: snapshot, now: now).state, "stale")
    }

    func testAgeTextHandlesFutureRetryTimestamps() throws {
        let now = try XCTUnwrap(UsageInsights.parseDate("2026-06-24T15:16:56Z"))
        let retry = try XCTUnwrap(UsageInsights.parseDate("2026-06-24T15:46:56Z"))

        XCTAssertEqual(UsageInsights.ageText(since: retry, now: now), "in 30m")
    }

    func testSourceFreshnessUsesCapturedAtForCheckedIdleSnapshots() throws {
        let now = try XCTUnwrap(UsageInsights.parseDate("2026-05-12T20:30:00Z"))
        let snapshot = UsageSnapshot(
            provider: "codex",
            source: "codex remote writer",
            updatedAt: "2026-05-04T03:23:21Z",
            capturedAt: "2026-05-12T20:28:24Z",
            eventAt: "2026-05-04T03:23:21Z",
            contributors: [],
            skills: [],
            subagents: []
        )

        XCTAssertEqual(UsageInsights.sourceFreshness(for: snapshot, now: now).state, "live")
        XCTAssertTrue(UsageInsights.sourceDetail(snapshot, now: now).contains("event 8d ago"))
    }

    func testWindowFreshnessUsesEventAtEvenWhenTrackerCheckedRecently() throws {
        let now = try XCTUnwrap(UsageInsights.parseDate("2026-05-14T04:40:00Z"))
        let snapshot = UsageSnapshot(
            provider: "claude",
            source: "claude token tracker keepalive",
            updatedAt: "2026-05-13T21:53:07Z",
            capturedAt: "2026-05-14T04:21:42Z",
            eventAt: "2026-05-13T21:53:07Z",
            currentSession: UsageSnapshot.WindowMetric(
                label: "Current session",
                usedPct: 100,
                resetLabel: "2:50 PM",
                resetAt: nil
            ),
            week: UsageSnapshot.WindowMetric(
                label: "Current week",
                usedPct: 84,
                resetLabel: "May 13 4 PM",
                resetAt: nil
            ),
            contributors: [],
            skills: [],
            subagents: []
        )

        XCTAssertEqual(UsageInsights.sourceFreshness(for: snapshot, now: now).state, "fresh")
        XCTAssertEqual(UsageInsights.windowFreshness(for: snapshot, now: now)?.state, "stale")
        XCTAssertTrue(UsageInsights.sourceDetail(snapshot, now: now).contains("rate limit 6h ago"))
        XCTAssertTrue(UsageInsights.sourceDetail(snapshot, now: now).contains("checked 18m ago"))
    }

    func testParseDateAcceptsMicrosecondsAndOffset() throws {
        XCTAssertEqual(UsageInsights.normalizeISO8601("2026-08-29T16:14:04.910903Z"), "2026-08-29T16:14:04.910Z")
        XCTAssertEqual(
            UsageInsights.normalizeISO8601("2026-09-03T02:09:29.213841+00:00"),
            "2026-09-03T02:09:29.213+00:00"
        )
        let zulu3 = try XCTUnwrap(UsageInsights.parseDate("2026-08-29T16:14:04.910Z"))
        let zulu6 = try XCTUnwrap(UsageInsights.parseDate("2026-08-29T16:14:04.910903Z"))
        let offset = try XCTUnwrap(UsageInsights.parseDate("2026-09-03T02:09:29.213841+00:00"))
        let offset3 = try XCTUnwrap(UsageInsights.parseDate("2026-09-03T02:09:29.213Z"))
        XCTAssertEqual(zulu3.timeIntervalSince1970, zulu6.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(offset.timeIntervalSince1970, offset3.timeIntervalSince1970, accuracy: 0.001)
    }

    func testWindowFreshnessPrefersOfficialWindowStampOverIdleSession() throws {
        let now = try XCTUnwrap(UsageInsights.parseDate("2026-08-29T16:20:00Z"))
        let snapshot = UsageSnapshot(
            provider: "grok",
            source: "grok cli billing + local sessions",
            sourceKind: "official_api",
            updatedAt: "2026-08-29T16:20:00Z",
            capturedAt: "2026-08-29T16:20:00Z",
            eventAt: "2026-08-27T04:56:54.375Z",
            week: UsageSnapshot.WindowMetric(
                label: "Grok weekly credits",
                usedPct: 1,
                resetLabel: "Sep 2 7:09 PM",
                resetAt: "2026-09-03T02:09:29.213Z",
                capturedAt: "2026-08-29T16:20:00Z",
                id: "week",
                eventAt: "2026-08-29T16:20:00Z",
                state: "live"
            ),
            contributors: [],
            skills: [],
            subagents: []
        )

        XCTAssertEqual(UsageInsights.sourceFreshness(for: snapshot, now: now).state, "live")
        XCTAssertEqual(UsageInsights.windowFreshness(for: snapshot, now: now)?.state, "live")
        XCTAssertFalse(UsageInsights.staleWindowProviders([snapshot], now: now).contains("Grok"))
        XCTAssertFalse(UsageInsights.staleSourceProviders([snapshot], now: now).contains("Grok"))
    }

    func testDailyRoomUsesISOResetForPace() throws {
        let now = try XCTUnwrap(UsageInsights.parseDate("2026-06-07T17:00:00Z"))
        let snapshot = UsageSnapshot(
            provider: "claude",
            week: UsageSnapshot.WindowMetric(
                label: "Current week",
                usedPct: 10,
                resetLabel: "Jun 10 17:00",
                resetAt: "2026-06-10T17:00:00Z"
            ),
            contributors: [],
            skills: [],
            subagents: []
        )

        let room = try XCTUnwrap(UsageInsights.dailyRoom(for: snapshot, now: now))
        XCTAssertEqual(room.headroomPct, 90)
        XCTAssertEqual(try XCTUnwrap(room.spendablePct), 30, accuracy: 0.001)
        XCTAssertEqual(room.daysToReset, 3)
        XCTAssertFalse(room.usesFullHeadroom)
    }

    func testDailyRoomParsesLegacyResetLabelForPace() throws {
        let now = try XCTUnwrap(UsageInsights.parseDate("2026-06-07T17:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let snapshot = UsageSnapshot(
            provider: "codex",
            week: UsageSnapshot.WindowMetric(
                label: "Codex weekly",
                usedPct: 10,
                resetLabel: "Jun 10 17:00",
                resetAt: nil
            ),
            contributors: [],
            skills: [],
            subagents: []
        )

        let room = try XCTUnwrap(UsageInsights.dailyRoom(for: snapshot, now: now, calendar: calendar))
        XCTAssertEqual(room.headroomPct, 90)
        XCTAssertEqual(try XCTUnwrap(room.spendablePct), 30, accuracy: 0.001)
        XCTAssertEqual(room.daysToReset, 3)
        XCTAssertTrue(room.resetKnown)
    }

    func testDailyRoomUsesFullHeadroomInsideOneDay() throws {
        let now = try XCTUnwrap(UsageInsights.parseDate("2026-06-07T17:00:00Z"))
        let snapshot = UsageSnapshot(
            provider: "gemini",
            week: UsageSnapshot.WindowMetric(
                label: "Quota",
                usedPct: 36,
                resetLabel: "Jun 8 03:00",
                resetAt: "2026-06-08T03:00:00Z"
            ),
            contributors: [],
            skills: [],
            subagents: []
        )

        let room = try XCTUnwrap(UsageInsights.dailyRoom(for: snapshot, now: now))
        XCTAssertEqual(room.headroomPct, 64)
        XCTAssertEqual(try XCTUnwrap(room.spendablePct), 64, accuracy: 0.001)
        XCTAssertEqual(room.daysToReset, 1)
        XCTAssertTrue(room.usesFullHeadroom)
    }

    /// "Even pace" must divide by the exact days left, not whole days
    /// rounded up: a reset 30 hours out is 1.25 days, not 2 whole days.
    func testDailyRoomUsesFractionalDaysNotWholeDaysForPace() throws {
        let now = try XCTUnwrap(UsageInsights.parseDate("2026-06-07T17:00:00Z"))
        let snapshot = UsageSnapshot(
            provider: "claude",
            week: UsageSnapshot.WindowMetric(
                label: "Current week",
                usedPct: 50,
                resetLabel: "Jun 8 23:00",
                resetAt: "2026-06-08T23:00:00Z"
            ),
            contributors: [],
            skills: [],
            subagents: []
        )

        let room = try XCTUnwrap(UsageInsights.dailyRoom(for: snapshot, now: now))
        XCTAssertEqual(room.headroomPct, 50)
        // 50% headroom / 1.25 exact days = 40%/day, not 50/2 = 25%/day.
        XCTAssertEqual(try XCTUnwrap(room.spendablePct), 40, accuracy: 0.001)
        // The whole-day count used for "Nd to reset" copy still rounds up.
        XCTAssertEqual(room.daysToReset, 2)
        XCTAssertFalse(room.usesFullHeadroom)
    }

    func testBudgetEvaluatorPreservesUnknownWindowMetrics() throws {
        let provider = "test-unknown-window"
        let cleanupURLs = UsagePaths.budgetStateCandidates(provider: provider) + [UsagePaths.budgetStateURL(provider: provider)]
        cleanupURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        defer { cleanupURLs.forEach { try? FileManager.default.removeItem(at: $0) } }

        let snapshot = UsageSnapshot(
            provider: provider,
            displayName: "Test Unknown Window",
            updatedAt: "2026-05-04T03:23:21Z",
            capturedAt: "2026-05-12T20:28:24Z",
            eventAt: "2026-05-04T03:23:21Z",
            session: UsageSnapshot.SessionMetrics(
                costUSD: nil,
                durationAPI: nil,
                durationWall: nil,
                codeAdded: nil,
                codeRemoved: nil,
                input: nil,
                output: nil,
                cacheRead: nil,
                cacheWrite: nil,
                reasoningOutput: nil,
                total: 123,
                lastInput: nil,
                lastOutput: nil,
                lastCacheRead: nil,
                lastReasoningOutput: nil,
                lastTotal: 45,
                contextWindow: nil
            ),
            contributors: [],
            skills: [],
            subagents: []
        )

        BudgetEvaluator.evaluateAndPersist(snapshot: snapshot)
        let budget = try XCTUnwrap(BudgetStateReader.load(provider: provider))
        XCTAssertNil(budget.weeklyUsedPct)
        XCTAssertNil(budget.currentSessionUsedPct)
    }

    // A missing Fable weekly reading must never render as "0%" — that would
    // read as "Fable used none of its budget" when the truth is "we haven't
    // heard from the official /usage fetch since the last reset."
    func testFableDisplayNeverShowsZeroPercentForMissingReading() {
        let missing = FableDisplay.make(week: nil, expired: false)
        XCTAssertNil(missing.usedPct)
        XCTAssertEqual(missing.percentText, "--")
        XCTAssertFalse(missing.percentText.contains("0%"))
        XCTAssertTrue(missing.subline.contains("no reading"))
        XCTAssertTrue(missing.subline.contains("refreshes about every 5 min"))

        let expired = FableDisplay.make(week: nil, expired: true)
        XCTAssertNil(expired.usedPct)
        XCTAssertEqual(expired.percentText, "--")
        XCTAssertTrue(expired.subline.contains("no reading"))

        let reading = FableDisplay.make(week: UsageSnapshot.WindowMetric(label: "Current week (Fable)", usedPct: 12, resetLabel: "Mon 9 AM"), expired: false)
        XCTAssertEqual(reading.usedPct, 12)
        XCTAssertEqual(reading.percentText, "12%")
        // Lane reset wording carries the date ("Mon Oct 5, 9 AM", or
        // "tomorrow 9 AM" when it is next), so only the parts are fixed.
        XCTAssertTrue(reading.subline.hasPrefix("resets "))
        XCTAssertTrue(reading.subline.contains("9 AM"))
    }

    func testFableDisplayShouldShowGatesOnReadingOrExpiry() {
        XCTAssertFalse(FableDisplay.shouldShow(week: nil, expired: false))
        XCTAssertTrue(FableDisplay.shouldShow(week: nil, expired: true))
        XCTAssertTrue(FableDisplay.shouldShow(week: UsageSnapshot.WindowMetric(usedPct: 5), expired: false))
    }

    // The keepalive writer refetches the official reading about every 10
    // minutes, so a reading that old (or older) means the refetch is
    // failing, not that the panel is simply between ticks. The row must say
    // so instead of showing a silently aging percentage.
    func testFableDisplayFlagsReadingOlderThanRefreshInterval() {
        let now = Date()
        let iso = ISO8601DateFormatter()
        let old = FableDisplay.make(
            week: UsageSnapshot.WindowMetric(
                label: "Current week (Fable)",
                usedPct: 8,
                resetLabel: "Mon 9 AM",
                capturedAt: iso.string(from: now.addingTimeInterval(-90 * 60))
            ),
            expired: false,
            now: now
        )
        XCTAssertEqual(old.usedPct, 8)
        // Same words every lane uses: "updated 1h ago", tagged old.
        XCTAssertTrue(old.subline.contains("updated"))
        XCTAssertTrue(old.subline.contains("ago"))
        XCTAssertEqual(old.freshness?.state, .old)
        XCTAssertFalse(old.trust.isLive)
        XCTAssertTrue(old.helpText.contains("Run diagnostics"))

        let fresh = FableDisplay.make(
            week: UsageSnapshot.WindowMetric(
                label: "Current week (Fable)",
                usedPct: 8,
                resetLabel: "Mon 9 AM",
                capturedAt: iso.string(from: now.addingTimeInterval(-5 * 60))
            ),
            expired: false,
            now: now
        )
        // A live reading still says how old it is, so a timed refresh
        // never passes for a live feed.
        XCTAssertTrue(fresh.subline.contains("5m ago"))
        XCTAssertFalse(fresh.subline.contains("updated"))
    }

    func testRateLimitExpiredDecodesRoundTrip() throws {
        let json = """
        {
          "schemaVersion": 1,
          "provider": "claude",
          "rateLimitExpired": ["weekFable"],
          "rateLimitExpiredAt": "2026-08-20T09:00:00Z",
          "contributors": [], "skills": [], "subagents": []
        }
        """

        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.rateLimitExpired, ["weekFable"])
        XCTAssertEqual(snapshot.rateLimitExpiredAt, "2026-08-20T09:00:00Z")
    }
}
