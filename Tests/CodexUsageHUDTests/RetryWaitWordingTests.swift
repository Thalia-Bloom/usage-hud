import XCTest
@testable import CodexUsageHUD

final class RetryWaitWordingTests: XCTestCase {
    func testRetryWaitReadsNaturally() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let cases: [(TimeInterval, String, String)] = [
            (30, "1m", "1 minute"),
            (300, "5m", "5 minutes"),
            (3_540, "59m", "59 minutes"),
            (3_600, "1h", "1 hour"),
            (10_800, "3h", "3 hours")
        ]
        for (seconds, compact, spoken) in cases {
            let status = UsageSnapshot.ProviderHealth(status: "rate_limited",
                retryAt: now.addingTimeInterval(seconds).ISO8601Format())
            let recovery = try XCTUnwrap(RateLimitRecovery.make(status: status, now: now))
            XCTAssertEqual(recovery.note, "retry in \(compact)", "Wait: \(seconds)s")
            XCTAssertTrue(recovery.detail.contains("about \(spoken)."), recovery.detail)
            XCTAssertTrue(recovery.detail.contains("retry automatically"))
        }
    }
}
