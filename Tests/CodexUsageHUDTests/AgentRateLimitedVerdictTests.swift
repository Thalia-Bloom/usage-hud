import XCTest
@testable import CodexUsageHUD

final class AgentRateLimitedVerdictTests: XCTestCase {
    func testRateLimitedLaneVerdictSaysItRetriesAutomatically() throws {
        var snapshot = AgentFixtures.snapshot("claude", week: 30, readingAge: 20 * 60)
        snapshot.officialUsageStatus = .init(
            status: "rate_limited", updatedAt: AgentFixtures.iso(0), retryAt: AgentFixtures.iso(10 * 60)
        )
        let summary = AgentFixtures.summary([snapshot])

        XCTAssertEqual(summary.verdict.mode, "CHECK")
        XCTAssertTrue(summary.verdict.sentence.contains("provider cooldown"))
        XCTAssertTrue(summary.verdict.sentence.contains("retries automatically"))
        XCTAssertTrue(summary.verdict.sentence.contains("20m old"))
        XCTAssertFalse(summary.verdict.sentence.contains("refresh it"))
        XCTAssertEqual(MiniSchemaValidator.errors(try AgentFixtures.json(summary), schema: AgentSchema.summary), [])
    }
}
