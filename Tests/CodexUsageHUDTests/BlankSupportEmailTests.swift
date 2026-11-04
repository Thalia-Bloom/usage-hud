import XCTest
@testable import CodexUsageHUD

final class BlankSupportEmailTests: XCTestCase {
    func testBlankEmailDraftCarriesAppAndMacOSVersions() throws {
        let components = try XCTUnwrap(URLComponents(url: SupportReport.emailURL(), resolvingAgainstBaseURL: false))
        let body = try XCTUnwrap(components.queryItems?.first { $0.name == "body" }?.value)
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        XCTAssertEqual(body, "What I expected:\n\nWhat happened:\n\nUsage HUD version: \(AppInfo.resolvedMarketingVersion)\nmacOS version: \(system)\nAffected tool:\n")
        XCTAssertFalse(body.contains(NSHomeDirectory()))
        XCTAssertFalse(body.contains(NSUserName()))
        XCTAssertEqual(components.scheme, "mailto")
        XCTAssertEqual(components.path, "support@thaliabloom.com")
        XCTAssertEqual(components.queryItems?.map(\.name), ["subject", "body"])
        XCTAssertEqual(components.queryItems?.first?.value, "Usage HUD help")
    }
}
