import XCTest
@testable import CodexUsageHUD

final class HeroVerdictTests: XCTestCase {
    func testGreenNamesThePrimaryLane() {
        let r = HeroVerdict.resolve(mode: "green", laneName: "Codex", readingFresh: true, paceStatus: "ON PACE")
        XCTAssertEqual(r, .init(mode: "green", tagline: "Codex: clear to build"))
    }

    func testStaleReadingIsCheckForThatLane() {
        let r = HeroVerdict.resolve(mode: "green", laneName: "Codex", readingFresh: false, paceStatus: "ON PACE")
        XCTAssertEqual(r, .init(mode: "check", tagline: "Codex: check reading"))
    }

    /// The panel once said "GO · Claude: clear to build" directly above a
    /// Claude row reading "Running hot · this pace → empty ~Fri 1 AM".
    func testGoNeverSitsBesideRunningHot() {
        let r = HeroVerdict.resolve(mode: "green", laneName: "Claude", readingFresh: true, paceStatus: "RUNNING HOT")
        XCTAssertEqual(r, .init(mode: "yellow", tagline: "Claude: running hot"))
        XCTAssertEqual(
            HeroVerdict.resolve(mode: "green", laneName: "Claude", readingFresh: true, paceStatus: "5H TIGHT").mode,
            "yellow"
        )
    }

    func testYellowWithHotPaceSaysWhy() {
        XCTAssertEqual(
            HeroVerdict.resolve(mode: "yellow", laneName: "Claude", readingFresh: true, paceStatus: "RUNNING HOT"),
            .init(mode: "yellow", tagline: "Claude: running hot")
        )
        XCTAssertEqual(
            HeroVerdict.resolve(mode: "yellow", laneName: "Claude", readingFresh: true, paceStatus: "ON PACE").tagline,
            "Claude: watch your spend"
        )
    }

    func testNonGreenModesPassThrough() {
        XCTAssertEqual(HeroVerdict.resolve(mode: "red", laneName: "Claude", readingFresh: true, paceStatus: "RUNNING HOT").mode, "red")
        XCTAssertEqual(HeroVerdict.resolve(mode: "unknown", laneName: nil, readingFresh: false, paceStatus: nil).tagline, "Waiting on data")
    }
}

final class HeroAlternativeTests: XCTestCase {
    private let codexRoom = HeroVerdict.Lane(name: "Codex", used: 22, paceStatus: "ON PACE", fresh: true)

    func testNamesRoomierLaneWhenPrimaryIsPressed() {
        let lanes = [
            HeroVerdict.Lane(name: "Claude", used: 42, paceStatus: "RUNNING HOT", fresh: true),
            codexRoom,
            HeroVerdict.Lane(name: "Gemini", used: 35, paceStatus: "ROOM TO BURN", fresh: true),
        ]
        XCTAssertEqual(HeroVerdict.alternative(mode: "yellow", primary: "Claude", lanes: lanes), "Codex has room · 22% used")
    }

    func testSilentWhenPrimaryIsFine() {
        XCTAssertNil(HeroVerdict.alternative(mode: "green", primary: "Claude", lanes: [codexRoom]))
    }

    func testSkipsStaleSpentAndHotLanes() {
        let lanes = [
            HeroVerdict.Lane(name: "Codex", used: 10, paceStatus: "ON PACE", fresh: false),
            HeroVerdict.Lane(name: "Gemini", used: 100, paceStatus: "✓ SPENT", fresh: true),
            HeroVerdict.Lane(name: "Grok", used: 30, paceStatus: "RUNNING HOT", fresh: true),
            HeroVerdict.Lane(name: "Grok 2", used: 75, paceStatus: "ON PACE", fresh: true),
        ]
        XCTAssertNil(HeroVerdict.alternative(mode: "red", primary: "Claude", lanes: lanes))
    }
}
