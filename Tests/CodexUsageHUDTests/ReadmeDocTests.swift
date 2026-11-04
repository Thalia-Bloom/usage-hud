import Foundation
import XCTest

final class ReadmeDocTests: XCTestCase {
    private func readme() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
    }

    func testHelpTabIsDocumentedAsShipped() throws {
        let text = try readme()
        XCTAssertFalse(text.lowercased().contains("candidate build"))
        XCTAssertTrue(text.contains("Help tab"))
    }

    func testLegacyStateDirectoryOverrideAppliesToHelpersOnly() throws {
        let text = try readme()
        let sentence = try XCTUnwrap(text.components(separatedBy: ". ")
            .first { $0.contains("`BLOOM_USAGE_DIR`") })
        XCTAssertTrue(sentence.contains("helpers only"))
        XCTAssertFalse(sentence.contains("app and every helper"))
        XCTAssertTrue(text.contains("`CODEX_USAGE_HUD_STATE_DIR` points the app and every helper"))
    }

    func testLocalOnlyPromiseIsPreserved() throws {
        XCTAssertTrue(try readme().contains(
            "Nothing leaves your Mac unless you turn on the optional public badge"))
    }
}
