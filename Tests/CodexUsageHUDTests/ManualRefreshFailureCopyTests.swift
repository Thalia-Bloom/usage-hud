import XCTest
@testable import CodexUsageHUD

final class ManualRefreshFailureCopyTests: XCTestCase {
    func testFailedRefreshCopyHasNoExitCode() {
        let result = ManualRefreshFeedback.finished(.failed(1), before: [], after: [], providers: [])
        let detail = result.detail.lowercased()

        for technicalWord in ["code", "exited", "helper"] {
            XCTAssertFalse(detail.contains(technicalWord), "Failure copy contains \(technicalWord)")
        }
        XCTAssertTrue(detail.contains("health check"))
        XCTAssertTrue(result.detail.contains("Help › Run health check"))
        XCTAssertTrue(result.needsAttention)
        XCTAssertNil(result.checkedAt)
        XCTAssertEqual(result.title, "Refresh couldn't finish")
    }
}
