import XCTest
@testable import CodexUsageHUD

final class LaneDisplayTests: XCTestCase {
    /// Wednesday 2026-09-30 at noon, local time, so day-boundary wording is stable.
    private let now: Date = {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 9; parts.day = 30; parts.hour = 12
        return Calendar.current.date(from: parts)!
    }()

    private func codex(used: Double, resetIn: TimeInterval) -> UsageSnapshot {
        UsageSnapshot(provider: "codex", capturedAt: now.ISO8601Format(),
                      week: .init(usedPct: used, resetAt: now.addingTimeInterval(resetIn).ISO8601Format()),
                      contributors: [], skills: [], subagents: [])
    }

    // The Codex row used to swap its reset date for the burn forecast. Both
    // must show: the reset on the first line, the forecast on its own line.
    func testRunningHotLaneKeepsResetDateBesideForecast() {
        let pace = lanePace(codex(used: 89, resetIn: 4 * 24 * 3600), now: now)
        XCTAssertEqual(pace.status, "RUNNING HOT")
        let lines = LaneLines.make(pace, todayNote: nil)
        XCTAssertEqual(lines.primary, "resets Sun Oct 4, 12 PM")
        XCTAssertTrue(lines.status?.hasPrefix("Running hot") == true)
        XCTAssertTrue(lines.status?.contains("this pace") == true)
    }

    func testSpentLaneSaysWhenItIsBack() {
        let pace = lanePace(codex(used: 100, resetIn: 2 * 24 * 3600 + 3600), now: now)
        let lines = LaneLines.make(pace, todayNote: nil)
        XCTAssertEqual(lines.primary, "Spent · back Fri Oct 2, 1 PM")
        XCTAssertNil(lines.status)
    }

    func testCalmLaneShowsResetAndEvenPace() {
        let pace = lanePace(codex(used: 2, resetIn: 6.9 * 24 * 3600), now: now)
        let lines = LaneLines.make(pace, todayNote: "even pace 14%/day")
        XCTAssertTrue(lines.primary?.hasPrefix("resets ") == true)
        XCTAssertTrue(lines.primary?.hasSuffix(" · even pace 14%/day") == true)
        XCTAssertFalse(lines.primaryIsGap)
    }

    func testMissingWindowIsFlaggedAsAGap() {
        let snapshot = UsageSnapshot(provider: "codex", capturedAt: now.ISO8601Format(),
                                     contributors: [], skills: [], subagents: [])
        let lines = LaneLines.make(lanePace(snapshot, now: now), todayNote: nil)
        XCTAssertNotNil(lines.primary)
        XCTAssertTrue(lines.primaryIsGap)
    }

    func testResetWordingReadsAloud() {
        let iso = { (offset: TimeInterval) in self.now.addingTimeInterval(offset).ISO8601Format() }
        XCTAssertEqual(laneResetText(nil, iso(90 * 60), now: now), "in 1h 30m")
        XCTAssertEqual(laneResetText(nil, iso(5 * 3600), now: now), "today 5 PM")
        XCTAssertEqual(laneResetText(nil, iso(24 * 3600 + 30 * 60), now: now), "tomorrow 12:30 PM")
        XCTAssertEqual(laneResetText(nil, iso(7 * 24 * 3600 + 4 * 3600), now: now), "Wed Oct 7, 4 PM")
        XCTAssertEqual(laneResetText("whenever", nil, now: now), "whenever")
    }
}
