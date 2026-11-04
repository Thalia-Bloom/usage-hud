import XCTest
@testable import CodexUsageHUD

final class RateLimitRecoveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func snapshot(retryAt: String?) -> UsageSnapshot {
        let old = now.addingTimeInterval(-86400).ISO8601Format()
        return UsageSnapshot(provider: "claude", sourceKind: "official_api", confidence: "high",
            capturedAt: now.ISO8601Format(), eventAt: old,
            week: .init(usedPct: 17, resetAt: now.addingTimeInterval(86400).ISO8601Format()),
            officialUsageStatus: .init(status: "rate_limited", updatedAt: now.ISO8601Format(), retryAt: retryAt),
            health: .init(verdict: "stale", reason: "Claude usage endpoint is rate-limited."))
    }

    func testOldReadingRemainsOldWhilePanelAndSetupExplainRetry() {
        let snap = snapshot(retryAt: now.addingTimeInterval(300).ISO8601Format())
        let freshness = UsageInsights.laneFreshness(for: snap, now: now)
        XCTAssertTrue(freshness.isOld)
        XCTAssertEqual(freshness.ageShort, "1d")
        XCTAssertEqual(freshness.note, "retry in 5m")
        XCTAssertEqual(HeaderStatus.make(lanes: [.init(name: "Claude", freshness: freshness)]).text, "Claude · retry in 5m")
        XCTAssertFalse(HeroVerdict.reading(for: snap, now: now).fresh)
        XCTAssertEqual(snap.week?.usedPct, 17)

        let setup = LaneSetupScoring.result(provider: "claude", snapshot: snap,
            nodeAvailable: true, pythonAvailable: true, now: now)
        XCTAssertFalse(setup.status.isSuccess)
        XCTAssertTrue(setup.line.contains("retry automatically"))
        XCTAssertFalse(setup.line.contains("refresh to try again"))
        let action = AgentSetup.failureAction(for: "claude", tool: "Claude Code", detail: setup.line)
        XCTAssertTrue(action.contains("retry automatically"))
        XCTAssertFalse(action.contains("run setup again"))
    }

    func testMissingInvalidAndElapsedRetryTimesNeverInventACountdown() {
        for stamp in [nil, "invalid", now.addingTimeInterval(-600).ISO8601Format()] as [String?] {
            let freshness = UsageInsights.laneFreshness(for: snapshot(retryAt: stamp), now: now)
            XCTAssertEqual(freshness.note, "usage rate-limited")
            XCTAssertTrue(freshness.issueDetail?.contains("run diagnostics") == true)
            XCTAssertTrue(freshness.isOld)
        }
    }

    func testRecentStatuslineReadingStaysLiveDuringOfficialCooldown() {
        var snap = snapshot(retryAt: now.addingTimeInterval(300).ISO8601Format())
        snap.eventAt = now.ISO8601Format()
        snap.health = .init(verdict: "fresh")
        let freshness = UsageInsights.laneFreshness(for: snap, now: now)
        XCTAssertEqual(freshness.state, .live)
        XCTAssertNil(freshness.issue)
        XCTAssertTrue(LaneSetupScoring.result(provider: "claude", snapshot: snap,
            nodeAvailable: true, pythonAvailable: true, now: now).status.isSuccess)
    }

    func testRateLimitRecoveryDoesNotRecommendSigningInOrExposeDetails() {
        let output = """
        WARN  claude health: stale
        WARN  claude official /usage: rate_limited · private-token /Users/josh/private · checked 46m ago
        WARN  fable weekly reading: 31% used
        WARN  claude windows: old
        :
        """
        for spacing in ["  ", "   ", "\t"] {
            let steps = SupportReport.nextSteps(output.replacingOccurrences(of: "WARN  ", with: "WARN" + spacing))
            XCTAssertEqual(steps.count, 1)
            XCTAssertTrue(steps[0].contains("automatic retries"))
            XCTAssertFalse(steps[0].contains("check that you are signed in"))
            XCTAssertFalse(steps[0].contains("private-token"))
        }
        let report = SupportReport.text(output, version: "1", build: "1", system: "14")
        XCTAssertFalse(report.contains("private-token"))
        XCTAssertFalse(report.contains("/Users/josh"))
    }
}
