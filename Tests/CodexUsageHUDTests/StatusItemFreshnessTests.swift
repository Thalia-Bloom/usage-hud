import XCTest
@testable import CodexUsageHUD

final class StatusItemFreshnessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_400_000)

    private func snapshot(age: TimeInterval) throws -> UsageSnapshot {
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-age))
        let json = """
        {"provider":"claude","capturedAt":"\(stamp)","week":{"usedPct":28},"weekFable":{"usedPct":95}}
        """
        return try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
    }

    func testOldReadingIsMarkedInTooltipAndVoiceOver() throws {
        let budget = BudgetState(mode: "yellow", modeLabel: "", weeklyUsedPct: 28,
                                 weeklyResetLabel: nil, currentSessionUsedPct: nil,
                                 allowedWork: [], subagentPolicy: nil, driverAlerts: [], updatedAt: nil)
        let readings = StatusItemText.readings(providers: ["claude"],
            snapshots: [try snapshot(age: 86_400)], budgets: ["claude": budget], now: now)
        XCTAssertTrue(readings.allSatisfy(\.isOld))
        XCTAssertEqual(StatusItemText.laneSummary(readings[0]), "Claude 28% of week · old reading")
        XCTAssertTrue(StatusItemText.tooltip(readings).contains("Claude 28% of week · old reading"))
        XCTAssertEqual(StatusItemText.accessibilityValue(readings),
                       "Claude 28% of week, old reading; Fable 95% of week, old reading")
        for text in [StatusItemText.tooltip(readings), StatusItemText.accessibilityValue(readings)] {
            XCTAssertFalse(text.contains("running hot"))
            XCTAssertFalse(text.contains("nearly out"))
        }
    }

    func testFreshReadingKeepsItsStatus() throws {
        let readings = StatusItemText.readings(providers: ["claude"],
            snapshots: [try snapshot(age: 60)], budgets: [:], now: now)
        XCTAssertFalse(readings[0].isOld)
        XCTAssertFalse(readings[1].isOld)
        XCTAssertEqual(StatusItemText.laneSummary(readings[0]), "Claude 28% of week")
        XCTAssertEqual(StatusItemText.laneSummary(readings[1]), "Fable 95% of week · nearly out")
    }
}
