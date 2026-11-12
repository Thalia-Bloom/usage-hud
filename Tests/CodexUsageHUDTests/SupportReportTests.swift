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

    func testQuickDiagnosticsNeverIncludesSecretsPathsAccountsOrUsageNumbers() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let json = """
        {"provider":"claude","sourceKind":"/Users/josh/.claude/secret","capturedAt":"2026-09-17T14:00:00Z",
         "week":{"label":"week","usedPct":73.4},
         "officialUsageStatus":{"status":"unauthorized","message":"Bearer sk-ant-oat01-SECRET /Users/josh josh@example.com"},
         "health":{"verdict":"degraded","reason":"token=sk-ant-secret-9999"}}
        """
        let snap = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        let out = SupportReport.quickDiagnostics(
            snapshots: [snap], installed: true, openAtLogin: true, nodeAvailable: true, pythonAvailable: true,
            version: "1.3.4", build: "40", system: "15.0", now: now
        )
        XCTAssertTrue(out.contains("- claude: state=old"))
        XCTAssertTrue(out.contains("health=degraded status=unauthorized source=other"))
        for secret in ["sk-ant", "SECRET", "/Users/josh", "josh@example.com", "Bearer", "73.4", "73%"] {
            XCTAssertFalse(out.contains(secret), "leaked \(secret) in \(out)")
        }
    }

    func testLaneRecoveryExplainsDesktopAndRemoteAndKeychainLock() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let authJSON = """
        {"provider":"claude","capturedAt":"2026-09-17T14:00:00Z",
         "officialUsageStatus":{"status":"no_credential","message":"not signed in"},
         "health":{"verdict":"degraded","reason":"not signed in"}}
        """
        let authSnap = try JSONDecoder().decode(UsageSnapshot.self, from: Data(authJSON.utf8))
        let authFresh = UsageInsights.laneFreshness(for: authSnap, now: now)
        XCTAssertEqual(authFresh.issue, "sign in again")
        let recovery = try XCTUnwrap(LaneRecovery.make(provider: "claude", snapshot: authSnap, freshness: authFresh))
        XCTAssertTrue(recovery.why.contains("Claude Desktop"))
        XCTAssertTrue(recovery.why.contains("remote"))
        XCTAssertEqual(recovery.command, "claude")

        let lockJSON = """
        {"provider":"claude","capturedAt":"2026-09-17T14:00:00Z",
         "officialUsageStatus":{"status":"keychain_locked","message":"locked"},
         "health":{"verdict":"degraded","reason":"locked"}}
        """
        let lockSnap = try JSONDecoder().decode(UsageSnapshot.self, from: Data(lockJSON.utf8))
        let lockFresh = UsageInsights.laneFreshness(for: lockSnap, now: now)
        XCTAssertEqual(lockFresh.issue, "allow Keychain access")
        XCTAssertEqual(HeaderStatus.make(lanes: [.init(name: "Claude", freshness: lockFresh)]).text, "Claude · allow Keychain access")
        XCTAssertNil(LaneRecovery.make(provider: "claude", snapshot: lockSnap, freshness: lockFresh)?.command)
    }
}
