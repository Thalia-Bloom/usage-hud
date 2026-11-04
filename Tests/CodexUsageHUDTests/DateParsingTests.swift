import Foundation
import XCTest
@testable import CodexUsageHUD

final class DateParsingTests: XCTestCase {
    func testSupportedTimestampFormats() throws {
        let noon = Date(timeIntervalSince1970: 1_704_110_400) // 2024-01-01 12:00 UTC
        let cases: [(String, TimeInterval)] = [
            ("2024-01-01T12:00:00Z", 0),
            ("2024-01-01T12:00:00.123Z", 0.123),
            ("2024-01-01T12:00:00.123456+00:00", 0.123),
            ("2024-01-01T12:00:00.1Z", 0.1),
            ("2024-01-01T05:00:00-07:00", 0),
            ("2024-01-01T05:00:00.123-07:00", 0.123),
        ]
        // Normalization preserves milliseconds and truncates longer fractions.
        for (timestamp, fraction) in cases {
            let date = try XCTUnwrap(UsageInsights.parseDate(timestamp), timestamp)
            XCTAssertEqual(date.timeIntervalSince1970,
                           noon.addingTimeInterval(fraction).timeIntervalSince1970,
                           accuracy: 0.000001, timestamp)
        }
    }

    func testMissingAndInvalidDatesReturnNil() {
        XCTAssertNil(UsageInsights.parseDate(nil))
        XCTAssertNil(UsageInsights.parseDate(""))
        XCTAssertNil(UsageInsights.parseDate("not a date"))
    }
}
