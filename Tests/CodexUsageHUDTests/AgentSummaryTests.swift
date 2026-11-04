import XCTest
@testable import CodexUsageHUD

private typealias F = AgentFixtures

final class AgentPaceTests: XCTestCase {
    private func eval(_ snap: UsageSnapshot) -> AgentPace.Evaluation {
        AgentPace.evaluate(snap, now: F.now)
    }

    func testRunningHotForecastsEmptyTime() {
        // 60% used with 3 of 7 days gone: 17 points ahead of the clock.
        let e = eval(F.snapshot("claude", week: 60, weekResetIn: 4 * F.day))
        XCTAssertEqual(e.pace, "running_hot")
        XCTAssertEqual(e.status, "RUNNING HOT")
        // 60% in 3 days → the last 40% takes 2 more days.
        XCTAssertEqual(e.forecastEmptyAt, F.now.addingTimeInterval(2 * F.day))
    }

    func testRoomAndOnPaceBands() {
        XCTAssertEqual(eval(F.snapshot("claude", week: 10, weekResetIn: 3 * F.day)).pace, "room")
        XCTAssertEqual(eval(F.snapshot("claude", week: 50, weekResetIn: 3.5 * F.day)).pace, "on_pace")
        // Exactly 15 points ahead is still on pace; the band is strict.
        XCTAssertEqual(eval(F.snapshot("claude", week: 65, weekResetIn: 3.5 * F.day)).pace, "on_pace")
        XCTAssertEqual(eval(F.snapshot("claude", week: 65.5, weekResetIn: 3.5 * F.day)).pace, "running_hot")
        XCTAssertEqual(eval(F.snapshot("claude", week: 35, weekResetIn: 3.5 * F.day)).pace, "on_pace")
        XCTAssertEqual(eval(F.snapshot("claude", week: 34.5, weekResetIn: 3.5 * F.day)).pace, "room")
        XCTAssertNil(eval(F.snapshot("claude", week: 50, weekResetIn: 3.5 * F.day)).forecastEmptyAt)
    }

    func testSpentThresholds() {
        XCTAssertEqual(eval(F.snapshot("codex", week: 99.5)).pace, "spent")
        XCTAssertEqual(eval(F.snapshot("codex", week: 99.5)).status, "SPENT")
        XCTAssertEqual(eval(F.snapshot("codex", week: 99.4)).pace, "almost_spent")
        XCTAssertEqual(eval(F.snapshot("codex", week: 90)).pace, "almost_spent")
        XCTAssertEqual(eval(F.snapshot("codex", week: 89.9)).pace, "running_hot")
    }

    func testTightFiveHourWindowHeadlinesTheLane() {
        let tight = F.summary([F.snapshot("claude", week: 30, session: 96, sessionResetIn: 2 * F.hour)])
        let lane = tight.lane("claude")!
        XCTAssertEqual(lane.status, "5H TIGHT")
        XCTAssertEqual(lane.window, "5h")
        XCTAssertEqual(lane.usedPercent, 96)
        XCTAssertEqual(lane.pace, "almost_spent")
        XCTAssertEqual(lane.resetsIn, "2h")
        XCTAssertNil(tight.roomNow, "a lane whose 5-hour window is nearly full has no room right now")

        let full = F.summary([F.snapshot("claude", week: 30, session: 100)])
        XCTAssertEqual(full.lane("claude")?.status, "5H FULL")
        XCTAssertEqual(full.lane("claude")?.pace, "spent")
    }

    func testResetsSoonStillReportsPace() {
        let e = eval(F.snapshot("claude", week: 50, weekResetIn: 30 * 60))
        XCTAssertEqual(e.status, "RESETS SOON")
        XCTAssertEqual(e.pace, "room")
    }

    func testGeminiDailyQuotaUsesADayWindow() {
        let lane = F.summary([F.snapshot("gemini", week: 20, weekResetIn: 10 * F.hour, weekLabel: "Gemini quota")]).lane("gemini")!
        XCTAssertEqual(lane.window, "day")
        XCTAssertEqual(lane.pace, "room") // 20% used, 58% of the day gone
        XCTAssertEqual(lane.windows.first?.window, "day")
    }

    func testExpiredAndPassedWindowsNeverShowAPercent() {
        let expired = F.summary([F.snapshot("claude", week: 70, weekResetIn: -F.hour, weekState: "expired")]).lane("claude")!
        XCTAssertNil(expired.usedPercent)
        XCTAssertEqual(expired.status, "IDLE")
        XCTAssertEqual(expired.pace, "unknown")
        XCTAssertEqual(expired.windows.first?.state, "expired")
        XCTAssertNotNil(expired.note)

        let passed = F.summary([F.snapshot("claude", week: 40, weekResetIn: -F.hour)]).lane("claude")!
        XCTAssertNil(passed.usedPercent)
        XCTAssertEqual(passed.status, "RESET PASSED")
        XCTAssertEqual(passed.windows.first?.state, "reset_passed")
    }

    /// Agents use the panel's freshness rule: a weekly reading is old after
    /// six hours (LaneFreshness.oldReadingSeconds), not after 30 minutes.
    func testStaleFollowsThePanelRule() {
        let fresh = F.summary([F.snapshot("claude", week: 40, readingAge: 45 * 60)]).lane("claude")!
        XCTAssertFalse(fresh.stale)
        XCTAssertEqual(fresh.readingAgeSeconds, 45 * 60)
        XCTAssertEqual(fresh.readingAge, "45m")
        let old = F.summary([F.snapshot("claude", week: 40, readingAge: 7 * 3600)]).lane("claude")!
        XCTAssertTrue(old.stale)
    }

    /// AgentPace duplicates UsageView.lanePace (a UI file). Hold the two to
    /// the same verdict on every fixture so a threshold change in one shows
    /// up here.
    func testMatchesPanelLanePace() {
        let cases: [UsageSnapshot] = [
            F.snapshot("claude", week: 60, weekResetIn: 4 * F.day),
            F.snapshot("claude", week: 10, weekResetIn: 3 * F.day),
            F.snapshot("claude", week: 50, weekResetIn: 3.5 * F.day),
            F.snapshot("claude", week: 65, weekResetIn: 3.5 * F.day),
            F.snapshot("claude", week: 65.5, weekResetIn: 3.5 * F.day),
            F.snapshot("codex", week: 99.5),
            F.snapshot("codex", week: 90),
            F.snapshot("claude", week: 30, session: 96),
            F.snapshot("claude", week: 30, session: 100),
            F.snapshot("claude", week: 50, weekResetIn: 30 * 60),
            F.snapshot("gemini", week: 20, weekResetIn: 10 * F.hour, weekLabel: "Gemini quota"),
            F.snapshot("claude", week: 70, weekResetIn: -F.hour, weekState: "expired"),
            F.snapshot("claude", week: 40, weekResetIn: -F.hour),
            F.snapshot("claude", week: nil, weekState: "unknown"),
            F.snapshot("codex", session: 40, sessionResetIn: 4 * F.hour),
            F.snapshot("claude", week: 40, weekResetIn: nil),
        ]
        for snap in cases {
            let panel = lanePace(snap, now: F.now)
            let agent = AgentPace.evaluate(snap, now: F.now)
            let panelStatus = panel.status == "✓ SPENT" ? "SPENT" : panel.status
            XCTAssertEqual(agent.status, panelStatus, "status for \(snap.provider) week=\(String(describing: snap.week?.usedPct))")
            XCTAssertEqual(agent.used, panel.used, "used for \(snap.provider)")
            XCTAssertEqual(agent.historical, panel.historical)
            XCTAssertEqual(agent.derived, panel.derived)
            XCTAssertEqual(agent.stale, UsageInsights.laneFreshness(for: snap, now: F.now).isOld)
        }
    }
}

final class AgentVerdictTests: XCTestCase {
    func testFleetGoesWithClaudeAndNamesTheRoomiestLane() {
        let s = F.summary(F.fleet)
        XCTAssertEqual(s.schemaVersion, 1)
        XCTAssertEqual(s.verdict, .init(mode: "GO", lane: "claude", laneName: "Claude", sentence: "Claude: clear to build."))
        // Grok 8% beats Gemini 20% and Claude 40%; Codex is almost spent,
        // Local has no plan limit.
        XCTAssertEqual(s.roomNow?.lane, "grok")
        XCTAssertEqual(s.roomNow?.usedPercent, 8)
        XCTAssertEqual(s.lanes.map(\.provider), ["claude", "codex", "gemini", "grok", "local"])
        XCTAssertEqual(s.lane("claude")?.confidence, "measured")
        XCTAssertEqual(s.lane("codex")?.confidence, "official")
        XCTAssertEqual(s.lane("local")?.pace, "unknown")
    }

    func testPressedPrimaryIsWatchAndOffersTheLaneWithRoom() {
        let s = F.summary([F.snapshot("claude", week: 85), F.snapshot("codex", week: 20, weekResetIn: 3.5 * F.day)])
        XCTAssertEqual(s.verdict.mode, "WATCH")
        XCTAssertEqual(s.verdict.sentence, "Claude: running hot. Codex has room, 20% used.")
        XCTAssertEqual(s.roomNow?.lane, "codex")
    }

    func testGreenBudgetButRunningHotIsWatch() {
        let s = F.summary([F.snapshot("claude", week: 55, weekResetIn: 5 * F.day)])
        XCTAssertEqual(s.verdict.mode, "WATCH")
        XCTAssertEqual(s.verdict.sentence, "Claude: running hot.")
        XCTAssertNotNil(s.lane("claude")?.forecastEmptyAt)
    }

    func testNearlyOutIsStop() {
        let s = F.summary([F.snapshot("claude", week: 95)])
        XCTAssertEqual(s.verdict.mode, "STOP")
        XCTAssertEqual(s.verdict.sentence, "Claude: nearly out.")
        XCTAssertNil(s.roomNow)
    }

    func testOldReadingIsCheckAndSaysHowOld() {
        let s = F.summary([F.snapshot("claude", week: 30, readingAge: 20 * 60)])
        XCTAssertEqual(s.verdict.mode, "CHECK")
        XCTAssertEqual(s.verdict.sentence, "Claude: check reading. The last Claude reading is 20m old; open Usage HUD to refresh it.")
    }

    func testNoDataIsCheckWithNoLane() {
        let s = F.summary([])
        XCTAssertEqual(s.verdict.mode, "CHECK")
        XCTAssertNil(s.verdict.lane)
        XCTAssertTrue(s.verdict.sentence.hasPrefix("Waiting on data."))
        XCTAssertNil(s.roomNow)
        XCTAssertFalse(s.hasAnyReading)
    }

    func testWithoutClaudeTheTightestLaneLeads() {
        let s = F.summary([F.snapshot("codex", week: 70), F.snapshot("gemini", week: 30)])
        XCTAssertEqual(s.verdict.lane, "codex")
        XCTAssertEqual(s.verdict.mode, "WATCH")
        XCTAssertEqual(s.verdict.sentence, "Codex: running hot. Gemini has room, 30% used.")
    }

    func testHiddenLanesAreLeftOut() {
        let s = F.summary(F.fleet, visible: ["codex", "gemini"])
        XCTAssertEqual(s.lanes.map(\.provider), ["codex", "gemini"])
        XCTAssertEqual(s.verdict.lane, "codex")
    }

    func testRoomNeedsAFreshUnpressedLaneUnderSixty() {
        XCTAssertNil(F.summary([F.snapshot("claude", week: 70), F.snapshot("codex", week: 65)]).roomNow)
        let staleCodex = F.summary([F.snapshot("claude", week: 40), F.snapshot("codex", week: 5, readingAge: 2 * F.hour)])
        XCTAssertEqual(staleCodex.roomNow?.lane, "claude")
    }

    func testRoomAdvice() {
        let fleet = AgentRoomAdvice(summary: F.summary(F.fleet))
        XCTAssertEqual(fleet.advice, "Claude: clear to build. Grok has the most room: 8% of its week used, on pace, resets in 6d.")
        XCTAssertEqual(fleet.usable.map(\.lane), ["grok", "gemini", "claude"])

        let pressed = AgentRoomAdvice(summary: F.summary([F.snapshot("claude", week: 85), F.snapshot("codex", week: 20)]))
        XCTAssertEqual(pressed.advice, "Claude: running hot. Move long or parallel work to Codex: 20% of its week used, room to spare, resets in 3d 12h.")

        let none = AgentRoomAdvice(summary: F.summary([F.snapshot("claude", week: 95, weekResetIn: 5 * F.hour)]))
        XCTAssertTrue(none.advice.hasPrefix("No plan clearly has room right now."))
        XCTAssertTrue(none.advice.contains("Claude resets in 5h"))

        let empty = AgentRoomAdvice(summary: F.summary([]))
        XCTAssertTrue(empty.advice.contains("click Set up"))
    }

    func testBudgetModeMatchesBudgetEvaluator() {
        for used in [0, 30, 60, 60.5, 80, 85, 90, 90.5, 99, 99.5, 100] as [Double] {
            XCTAssertEqual(
                AgentBudgetThresholds.standard.mode(weekly: used, session: nil),
                BudgetEvaluator.fallbackModeFromHeadroom(100 - used),
                "weekly \(used)%"
            )
        }
        XCTAssertEqual(AgentBudgetThresholds.standard.mode(weekly: 10, session: 96), "red")
        XCTAssertEqual(AgentBudgetThresholds.standard.mode(weekly: nil, session: nil), "unknown")
        let custom = AgentBudgetThresholds(policy: ["budgets": ["weeklyPct": ["greenMax": 50]]])
        XCTAssertEqual(custom.mode(weekly: 55, session: nil), "yellow")
    }
}

final class AgentSummaryContractTests: XCTestCase {
    func testStatusJSONValidatesAgainstPublishedSchema() throws {
        let fixtures: [[UsageSnapshot]] = [
            F.fleet,
            [],
            [F.snapshot("claude", week: 95)],
            [F.snapshot("claude", week: 70, weekResetIn: -F.hour, weekState: "expired")],
            [F.snapshot("claude", week: 30, session: 96)],
        ]
        for snapshots in fixtures {
            let s = F.summary(snapshots)
            let json = try F.json(s)
            XCTAssertEqual(MiniSchemaValidator.errors(json, schema: AgentSchema.summary), [], "summary for \(snapshots.map(\.provider))")
            XCTAssertEqual(MiniSchemaValidator.errors(try F.json(AgentRoomAdvice(summary: s)), schema: AgentSchema.roomAdvice), [])
            for lane in s.lanes {
                XCTAssertEqual(MiniSchemaValidator.errors(["lane": try F.json(lane)], schema: AgentSchema.laneDetail), [])
            }
        }
    }

    func testValidatorCatchesDrift() throws {
        var json = try XCTUnwrap(try F.json(F.summary(F.fleet)) as? [String: Any])
        json["surprise"] = 1
        var lanes = try XCTUnwrap(json["lanes"] as? [[String: Any]])
        lanes[0]["pace"] = "sprinting"
        lanes[0].removeValue(forKey: "stale")
        json["lanes"] = lanes
        let errors = MiniSchemaValidator.errors(json, schema: AgentSchema.summary)
        XCTAssertTrue(errors.contains { $0.contains("unexpected property surprise") })
        XCTAssertTrue(errors.contains { $0.contains("not in enum") })
        XCTAssertTrue(errors.contains { $0.contains("missing required stale") })
    }

    func testNullsAreExplicitAndTheShapeRoundTrips() throws {
        let s = F.summary([F.snapshot("claude", week: 95)])
        let data = try JSONEncoder().encode(s)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"roomNow\":null"))
        XCTAssertTrue(text.contains("\"forecastEmptyAt\":null"))
        XCTAssertEqual(try JSONDecoder().decode(AgentSummary.self, from: data), s)
    }

    func testNeverLeaksPathsOrWriterText() throws {
        var leaky = F.snapshot("codex", week: 20, sourceKind: "", sourcePath: "/Users/someone/.codex/auth.json",
                               source: "/Users/someone/private/notes.txt")
        leaky.loadedFromPath = "/Users/someone/.codex-usage-hud/codex-usage.json"
        leaky.week?.reason = "token sk-live-123 at /Users/someone/.secrets"
        let s = F.summary(F.fleet.filter { $0.provider != "codex" } + [leaky])
        let text = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        for needle in ["/Users", "credentials", "auth.json", "sk-live", ".secrets", "notes.txt", "sourcePath"] {
            XCTAssertFalse(text.contains(needle), "summary leaked \(needle)")
        }
        XCTAssertEqual(s.lane("codex")?.source, "local snapshot")
    }

    func testDurationText() {
        XCTAssertEqual(AgentSummary.durationText(seconds: 45), "45s")
        XCTAssertEqual(AgentSummary.durationText(seconds: 35 * 60), "35m")
        XCTAssertEqual(AgentSummary.durationText(seconds: 2 * 3600 + 600), "2h 10m")
        XCTAssertEqual(AgentSummary.durationText(seconds: 3 * 3600), "3h")
        XCTAssertEqual(AgentSummary.durationText(seconds: 4 * 86_400 + 2 * 3600 + 59), "4d 2h")
        XCTAssertNil(AgentSummary.durationText(until: F.now.addingTimeInterval(-5), now: F.now))
    }
}
