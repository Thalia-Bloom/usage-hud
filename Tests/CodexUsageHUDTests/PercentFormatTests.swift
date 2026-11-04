import XCTest
@testable import CodexUsageHUD

final class PercentFormatTests: XCTestCase {
    func testPanelAndSetupUseMenuBarPercentRules() {
        let cases: [(Double, String)] = [
            (99.6, "99%"),
            (0.3, "<1%"),
            (42, "42%"),
            (100, "100%"),
            (.nan, "--")
        ]

        for (value, expected) in cases {
            XCTAssertEqual(formatPercent(value), expected, "Panel percent for \(value)")
            XCTAssertEqual(LaneSetupScoring.percentText(value), expected, "Setup percent for \(value)")
        }
    }
}
