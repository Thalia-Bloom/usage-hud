import Foundation
import XCTest

final class InstallDocTests: XCTestCase {
    func testShippedInstallGuideHasOnlyAbsoluteLinks() throws {
        let guideURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("INSTALL.md")
        let guide = try String(contentsOf: guideURL, encoding: .utf8)
        let links = try NSRegularExpression(pattern: #"\[[^\]]+\]\(([^)]+)\)"#)
        let matches = links.matches(in: guide, range: NSRange(guide.startIndex..., in: guide))
        XCTAssertFalse(matches.isEmpty, "The shipped guide should contain documentation links")
        for match in matches {
            let range = try XCTUnwrap(Range(match.range(at: 1), in: guide))
            let target = String(guide[range])
            XCTAssertTrue(target.hasPrefix("https://"), "Shipped guide link must be absolute HTTPS: \(target)")
        }
        XCTAssertTrue(guide.contains("https://hud.thaliabloom.com/agents/"))
    }
}
