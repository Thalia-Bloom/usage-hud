import XCTest
@testable import CodexUsageHUD

final class SupportExperienceTests: XCTestCase {
    private let ready = LaneSetupResult(provider: "codex", name: "Codex", status: .success("Codex ✓ 1% of the week used"))
    private let waiting = LaneSetupResult(provider: "claude", name: "Claude", status: .failure("Claude — usage rate-limited"))

    func testOneWorkingProviderDoesNotHideAnotherProvidersProblem() {
        var card = SetupCardModel.hidden
        card.phase = .doneWithData
        card.lanes = [ready, waiting]
        XCTAssertTrue(card.needsAttention)
        XCTAssertEqual(card.heading, "Some readings need attention")
        for isSetup in [true, false] {
            let result = BackgroundJobsModel.readingResult(lanes: card.lanes, isSetup: isSetup, details: "")
            XCTAssertTrue(result.isWarning)
            XCTAssertTrue(result.headline.contains("others need attention"))
            XCTAssertEqual(result.lines.count, 2)
        }
        card.lanes = [ready]
        XCTAssertFalse(card.needsAttention)
        XCTAssertEqual(card.heading, "You’re ready")
        XCTAssertFalse(BackgroundJobsModel.readingResult(lanes: [ready], isSetup: true, details: "").isWarning)
    }

    func testOldLowPercentageDoesNotRecommendSpendingInTextOrVoiceOver() {
        let pace = LanePace(used: 17, elapsed: 60, windowTag: "wk", status: "ROOM TO BURN",
                            statusColor: .clear, barColor: .clear, valueColor: .clear, sub: nil)
        let freshness = LaneFreshness(state: .old, age: 86400, issue: "retry in 5m")
        let lines = LaneLines.make(pace, todayNote: "20% a day", freshness: freshness)
        XCTAssertNil(lines.status)
        XCTAssertEqual(lines.primary, "last read 1d ago")
        let spoken = LaneSpeech.lane(name: "Claude", pace: pace, resetSpoken: nil, freshness: freshness)
        XCTAssertTrue(spoken.contains("last reading 17 percent"))
        XCTAssertFalse(spoken.contains("plenty of room"))
        XCTAssertEqual(LaneLines.make(pace, todayNote: nil, freshness: .init(state: .live, age: 0)).status, "Plenty of room")
    }

    func testOldReadingWithoutIssueStillShowsItsAge() {
        let pace = LanePace(used: 17, elapsed: 60, windowTag: "wk", status: "ROOM TO BURN",
                            statusColor: .clear, barColor: .clear, valueColor: .clear, sub: nil)
        let lines = LaneLines.make(pace, todayNote: "20% a day", freshness: LaneFreshness(state: .old, age: 86400))
        XCTAssertEqual(lines.primary, "last read 1d ago")
        XCTAssertNil(lines.status)
    }

    func testAutomaticRecoveryClearsSetupWarningOnlyWithUsableData() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var card = SetupCardModel.hidden
        card.phase = .doneWithNoData
        card.lanes = [waiting]
        XCTAssertTrue(card.recoveringLanes(from: [], now: now).needsAttention)
        var snapshot = UsageSnapshot(provider: "claude", sourceKind: "official_api", confidence: "high",
            capturedAt: now.ISO8601Format(), eventAt: now.addingTimeInterval(-86400).ISO8601Format(),
            week: .init(usedPct: 17, resetAt: now.addingTimeInterval(86400).ISO8601Format()),
            health: .init(verdict: "stale"))
        XCTAssertTrue(card.recoveringLanes(from: [snapshot], now: now).needsAttention)
        snapshot.eventAt = now.ISO8601Format()
        snapshot.health = .init(verdict: "fresh")
        let recovered = card.recoveringLanes(from: [snapshot], now: now)
        XCTAssertFalse(recovered.needsAttention)
        XCTAssertEqual(recovered.phase, .doneWithData)
        XCTAssertEqual(recovered.heading, "You’re ready")
        card.phase = .blocked
        XCTAssertEqual(card.recoveringLanes(from: [snapshot], now: now).phase, .blocked)
    }

    func testEmailDraftCarriesOnlyReviewedReportAndEscapesQueryCharacters() throws {
        let raw = "WARN  claude official /usage: rate_limited · token=secret /Users/private\nWARN  /Users/private: private"
        let report = SupportReport.text(raw, version: "1.3.1", build: "11", system: "14")
        XCTAssertTrue(report.contains("Claude usage check — provider asked us to wait"))
        XCTAssertFalse(report.contains("secret"))
        XCTAssertFalse(report.contains("/Users"))
        let url = SupportReport.emailURL(report: report + "\nLiteral &bcc=other@example.test?")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "mailto")
        XCTAssertEqual(components.path, "support@thaliabloom.com")
        XCTAssertEqual(components.queryItems?.map(\.name), ["subject", "body"])
        XCTAssertEqual(components.queryItems?.last?.value, report + "\nLiteral &bcc=other@example.test?")
    }

    func testUnknownDiagnosticStatusCannotEscapeIntoReport() {
        let report = SupportReport.text("WARN  claude official /usage: secret-token · secret-message", version: "1", build: "1", system: "14")
        XCTAssertFalse(report.contains("secret"))
        XCTAssertTrue(report.contains("WARN  Claude usage check"))
    }

    @MainActor
    func testHelpMenuOpensInAppRecoveryPane() {
        let notification = expectation(forNotification: .usageHUDOpenSettings, object: nil) { note in
            note.userInfo?["pane"] as? String == SettingsPane.help.rawValue
        }
        AppMenuActions().helpAction(nil)
        wait(for: [notification], timeout: 1)
    }
}
