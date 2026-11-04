import XCTest
@testable import CodexUsageHUD

final class SpokenDurationTests: XCTestCase {
    func testRetryMinutesAreWords() {
        XCTAssertEqual(LaneSpeech.words("Claude · retry in 5m"), "Claude · retry in 5 minutes")
    }

    func testSingleHourIsSingular() {
        XCTAssertEqual(LaneSpeech.words("updated 1h ago"), "updated 1 hour ago")
    }

    func testMultipleHoursArePlural() {
        XCTAssertEqual(LaneSpeech.words("retry in 2h"), "retry in 2 hours")
    }

    func testOrdinaryTextStaysUnchanged() {
        XCTAssertEqual(LaneSpeech.words("2 lanes old"), "2 lanes old")
        XCTAssertEqual(LaneSpeech.words("25ms, 5meters, model2h"), "25ms, 5meters, model2h")
    }

    func testHeaderMinutesAndCompoundDurations() {
        XCTAssertEqual(LaneSpeech.words("updated 25m ago"), "updated 25 minutes ago")
        XCTAssertEqual(LaneSpeech.words("retry in 1h 1m"), "retry in 1 hour 1 minute")
        XCTAssertEqual(LaneSpeech.words("1s, 2d"), "1 second, 2 days")
    }

    func testOldLaneSpeaksRetryDuration() {
        let speech = LaneSpeech.spoken(LaneFreshness(state: .old, age: 86400, issue: "retry in 5m"))
            .joined(separator: ", ")
        XCTAssertTrue(speech.contains("retry in 5 minutes"))
        XCTAssertFalse(speech.contains("5m"))
        XCTAssertTrue(speech.contains("reading is 1 day old"))
    }
}
