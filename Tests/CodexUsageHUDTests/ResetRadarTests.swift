import XCTest
@testable import CodexUsageHUD

final class ResetRadarTests: XCTestCase {
    private let now = UsageInsights.parseDate("2026-11-18T12:00:00Z")!

    private func iso(_ offset: TimeInterval) -> String {
        now.addingTimeInterval(offset).ISO8601Format()
    }

    func testFreshWeeklyResetAppearsAsAvailable() {
        // 2 hours into a 7-day cycle with 1% used -> stateless .available
        let gemini = UsageSnapshot(
            provider: "gemini",
            confidence: "official",
            updatedAt: iso(-60),
            capturedAt: iso(-60),
            eventAt: iso(-60),
            week: .init(label: "Gemini weekly", usedPct: 1, resetAt: iso(7 * 86_400 - 2 * 3600)),
            contributors: [], skills: [], subagents: []
        )
        let items = ResetRadar.items(snapshots: [gemini], visibleProviders: ["gemini"], now: now)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].kind, .available)
        XCTAssertEqual(items[0].title, "Gemini weekly")
        XCTAssertTrue(items[0].detail.contains("99% left"))
        XCTAssertTrue(items[0].detail.hasPrefix("Reset 2h ago"))
    }

    func testResetMemoryDetectsStatefulRollover() {
        let t0 = now.addingTimeInterval(-3600)
        var mark = ResetMemory.step(nil, resetAt: now.addingTimeInterval(-60), used: 65, now: t0)
        XCTAssertNil(mark.resetAtTime)
        mark = ResetMemory.step(mark, resetAt: now.addingTimeInterval(7 * 86_400), used: 2, now: now.addingTimeInterval(-300))
        XCTAssertNotNil(mark.resetAtTime)

        let claude = UsageSnapshot(
            provider: "claude",
            confidence: "official",
            updatedAt: iso(-60),
            capturedAt: iso(-60),
            eventAt: iso(-60),
            week: .init(label: "Claude weekly", usedPct: 2, resetAt: iso(7 * 86_400)),
            contributors: [], skills: [], subagents: []
        )
        let items = ResetRadar.items(
            snapshots: [claude],
            visibleProviders: ["claude"],
            marks: ["claude.week": mark],
            now: now
        )
        XCTAssertEqual(items.first?.kind, .available)
        XCTAssertEqual(items.first?.title, "Claude weekly")
        XCTAssertTrue(items.first?.detail.contains("98% left") == true)

        // Crossing 25% used clears the fresh-reset highlight.
        mark = ResetMemory.step(mark, resetAt: now.addingTimeInterval(7 * 86_400), used: 26, now: now)
        XCTAssertNil(mark.resetAtTime)
    }

    func testUseBeforeResetCatchesUnusedExpiringRoom() {
        let grok = UsageSnapshot(
            provider: "grok",
            confidence: "official",
            updatedAt: iso(-60),
            capturedAt: iso(-60),
            eventAt: iso(-60),
            week: .init(label: "Grok weekly", usedPct: 35, resetAt: iso(14 * 3600)),
            contributors: [], skills: [], subagents: []
        )
        let items = ResetRadar.items(snapshots: [grok], visibleProviders: ["grok"], now: now)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].kind, .useSoon)
        XCTAssertEqual(items[0].title, "Grok weekly")
        XCTAssertTrue(items[0].detail.contains("65% left"))
    }

    func testSpentLaneShowsUnlockCountdown() {
        let codex = UsageSnapshot(
            provider: "codex",
            confidence: "official",
            updatedAt: iso(-60),
            capturedAt: iso(-60),
            eventAt: iso(-60),
            week: .init(label: "Codex weekly", usedPct: 100, resetAt: iso(20 * 3600)),
            contributors: [], skills: [], subagents: []
        )
        let items = ResetRadar.items(snapshots: [codex], visibleProviders: ["codex"], now: now)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].kind, .upcoming)
        XCTAssertTrue(items[0].detail.hasPrefix("Unlocks "))
        XCTAssertTrue(items[0].detail.contains("(20h)"))
    }

    func testResetPingWatchesEightyPercentAndHandlesEarlyRollover() {
        let reset0 = now.addingTimeInterval(5 * 86_400)
        let heavy = UsageSnapshot(
            provider: "codex",
            capturedAt: iso(0),
            week: .init(usedPct: 85, resetAt: reset0.ISO8601Format()),
            contributors: [], skills: [], subagents: []
        )
        var tracker = ResetPingTracker()
        XCTAssertTrue(tracker.observe([heavy], enabled: ["codex"], snoozed: false, now: now).isEmpty)
        XCTAssertEqual(tracker.watches.count, 1, "85% used should register a reset watch")

        let upgraded = UsageSnapshot(
            provider: "codex",
            capturedAt: iso(60),
            week: .init(usedPct: 0, resetAt: now.addingTimeInterval(7 * 86_400).ISO8601Format()),
            contributors: [], skills: [], subagents: []
        )
        let pings = tracker.observe([upgraded], enabled: ["codex"], snoozed: false, now: now.addingTimeInterval(60))
        XCTAssertEqual(pings.count, 1)
    }

    func testStaleTokenExpiredClaudeIsCheckAndOffersGeminiAlternative() {
        let claude = UsageSnapshot(
            provider: "claude",
            sourceKind: "official_api",
            confidence: "official",
            updatedAt: iso(-60),
            capturedAt: iso(-60),
            eventAt: iso(-5 * 3600),
            week: .init(usedPct: 4, resetAt: iso(6 * 86_400), eventAt: iso(-5 * 3600)),
            contributors: [], skills: [], subagents: [],
            officialUsageStatus: .init(status: "token_expired", updatedAt: iso(-60)),
            health: .init(verdict: "degraded", reason: "token expired", checkedAt: iso(-60))
        )
        let gemini = UsageSnapshot(
            provider: "gemini",
            sourceKind: "official_interactive",
            confidence: "official",
            updatedAt: iso(-60),
            capturedAt: iso(-60),
            eventAt: iso(-60),
            week: .init(usedPct: 0.2, resetAt: iso(7 * 86_400 - 120), eventAt: iso(-60)),
            contributors: [], skills: [], subagents: []
        )

        let gate = HeroVerdict.reading(for: claude, now: now)
        XCTAssertFalse(gate.fresh)
        XCTAssertEqual(gate.why, "open Claude Code once")

        let summary = AgentSummary.build(snapshots: [claude, gemini], visibleProviders: ["claude", "gemini"], now: now)
        XCTAssertEqual(summary.verdict.mode, "CHECK")
        XCTAssertTrue(summary.verdict.sentence.contains("open Claude Code once"))
        XCTAssertTrue(summary.verdict.sentence.contains("Gemini has room"))
    }
}
