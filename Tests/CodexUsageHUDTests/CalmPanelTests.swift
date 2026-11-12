import XCTest
@testable import CodexUsageHUD

final class CalmPanelTests: XCTestCase {
    private func lane(_ id: String, _ used: Double?, _ tone: CalmTone, reset: String? = "Wed 3 PM") -> CalmLane {
        CalmLane(id: id, name: id.capitalized, used: used, tone: tone, reset: reset)
    }

    func testHeadlineNamesMostRoomAndSpentPlans() {
        let lanes = [lane("claude", 92, .spent), lane("codex", 47, .hot), lane("grok", 62, .hot), lane("gemini", 96, .spent)]
        XCTAssertEqual(CalmHeadline.sorted(lanes).map(\.id), ["codex", "grok", "claude", "gemini"])
        let head = CalmHeadline.make(lanes)
        XCTAssertEqual(head.title, "Use Codex next.")
        XCTAssertEqual(head.sub, "Claude and Gemini are almost spent until they reset.")
        XCTAssertEqual(CalmHeadline.make([lane("claude", 95, .spent)]).title, "Everything is almost spent.")
        XCTAssertEqual(CalmHeadline.make([lane("claude", nil, .dim)]).title, "Waiting for fresh readings.")
        XCTAssertEqual(CalmHeadline.make([lane("codex", 0, .calm), lane("claude", 2, .dim)]).sub, "Claude needs a fresh reading.")
        XCTAssertEqual(CalmHeadline.make([lane("codex", 0, .calm), lane("claude", 10, .calm)]).sub, "Every plan has room.")
    }

    func testComeBackGoesFirstAndSaysSo() {
        let back = lane("claude", 4, .back)
        let lanes = [lane("codex", 2, .calm), back]
        XCTAssertEqual(CalmHeadline.sorted(lanes).first?.id, "claude", "the plan that came back moves to the top")
        XCTAssertEqual(CalmHeadline.make(lanes, back: back).title, "Claude is back.")
    }

    func testComeBackMarksResetAndEndsAtTenPercent() {
        let t0 = Date()
        var m = ComeBack.step(nil, resetAt: t0, used: 92, now: t0)
        XCTAssertNil(m.backAt)
        m = ComeBack.step(m, resetAt: t0.addingTimeInterval(7 * 86400), used: 3, now: t0.addingTimeInterval(60))
        XCTAssertNotNil(m.backAt)
        XCTAssertEqual(m.before, 92, "the bar drains from the last reading before the reset")
        m = ComeBack.step(m, resetAt: t0.addingTimeInterval(7 * 86400), used: 12, now: t0.addingTimeInterval(3600))
        XCTAssertNil(m.backAt, "green lasts until the plan passes 10% used")
    }

    func testToneRules() {
        func pace(_ used: Double?, _ status: String) -> LanePace {
            LanePace(used: used, elapsed: 20, windowTag: "wk", status: status, statusColor: .gray, barColor: .gray, valueColor: .gray, sub: nil)
        }
        XCTAssertEqual(CalmTone.make(pace(40, "ON PACE"), old: false, back: false), .calm)
        XCTAssertEqual(CalmTone.make(pace(47, "RUNNING HOT"), old: false, back: false), .hot)
        XCTAssertEqual(CalmTone.make(pace(91, "ALMOST SPENT"), old: false, back: false), .spent)
        XCTAssertEqual(CalmTone.make(pace(4, "ON PACE"), old: false, back: true), .back)
        XCTAssertEqual(CalmTone.make(pace(40, "ON PACE"), old: true, back: false), .dim)
    }

    func testOpenRowSentence() {
        let lines = LaneLines(primary: "resets Mon 2 PM · 1.2K credits", status: "Running hot · runs out ~1 AM at this pace")
        let d = CalmHeadline.detail(lines, status: "RUNNING HOT", age: "25m")
        XCTAssertEqual(d.head, "Running hot")
        XCTAssertEqual(d.rest, "Runs out ~1 AM at this pace. 1.2K credits. Read 25m ago.")
    }

    func testSpentAtOneHundredAlmostSpentBelow() {
        XCTAssertEqual(CalmHeadline.make([lane("grok", 0, .calm), lane("codex", 100, .spent)]).sub, "Codex is spent until it resets.")
        XCTAssertEqual(CalmHeadline.make([lane("grok", 0, .calm), lane("codex", 100, .spent), lane("claude", 99.9, .spent)]).sub,
                       "Codex is spent and Claude is almost spent until they reset.")
        XCTAssertEqual(CalmHeadline.make([lane("codex", 100, .spent), lane("claude", 100, .spent)]).title, "Everything is spent.")
        XCTAssertEqual(CalmHeadline.make([lane("codex", 100, .spent), lane("claude", 91, .spent)]).title, "Everything is almost spent.")
    }

    func testRowResetNeverCarriesDateAndTime() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let thu = cal.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 17, minute: 43))!
        let wed = cal.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 17, minute: 43))!
        let nov18 = cal.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 4, minute: 27))!
        XCTAssertEqual(calmRowReset(nov18, label: nil, now: thu), "Wed 4:27 AM", "inside a week: weekday and time")
        XCTAssertEqual(calmRowReset(nov18, label: nil, now: nov18.addingTimeInterval(-7 * 86400)), "Nov 18", "7 days out: the date alone")
        XCTAssertEqual(calmRowReset(nov18, label: nil, now: wed), "Nov 18", "a Wednesday reset seen on a Wednesday gets its date")
        XCTAssertEqual(calmRowReset(cal.date(byAdding: .hour, value: 2, to: thu)!, label: nil, now: thu), "in 2h")
        XCTAssertEqual(calmRowReset(cal.date(byAdding: .hour, value: 5, to: thu)!, label: nil, now: thu), "Thu 10:43 PM")
        XCTAssertEqual(calmRowReset(nil, label: "soon", now: thu), "soon")
    }
}
