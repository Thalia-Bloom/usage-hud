import XCTest
@testable import CodexUsageHUD

final class SupportReportTests: XCTestCase {
    func testReportCopiesOnlyKnownCheckLabelsAndStatuses() {
        let output = """
        OK  claude windows: secret-value /Users/private/session.json token=hidden
        FAIL  com.codexusagehud.app: pid 123 user@example.com
        WARN  /Users/private/project: a prompt or credential
        stray output with private content
        """
        let report = SupportReport.text(output, version: "1.3.1", build: "11", system: "14.0")
        XCTAssertTrue(report.contains("OK  Claude usage windows"))
        XCTAssertTrue(report.contains("FAIL  App process"))
        XCTAssertTrue(report.contains("WARN  Other health check"))
        for privateText in ["secret-value", "/Users", "token=", "hidden", "user@example.com", "pid 123", "stray output"] {
            XCTAssertFalse(report.contains(privateText), privateText)
        }
    }

    func testAppRecoveryDoesNotRepeatInternalServiceName() {
        let steps = SupportReport.nextSteps("FAIL  com.codexusagehud.app: spawn scheduled")
        XCTAssertEqual(steps.count, 1)
        XCTAssertTrue(steps[0].contains("Open Usage HUD from Applications"))
        XCTAssertFalse(steps[0].contains("com.codexusagehud"))
    }

    func testUnknownOutputCannotEnterSupportReport() {
        let report = SupportReport.text("ERROR credential=private", version: "1", build: "1", system: "14")
        XCTAssertTrue(report.contains("No completed checks"))
        XCTAssertFalse(report.contains("credential=private"))
    }
}
