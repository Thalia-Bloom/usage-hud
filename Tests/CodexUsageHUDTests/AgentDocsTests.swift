import Foundation
import XCTest
@testable import CodexUsageHUD

final class AgentDocsTests: XCTestCase {
    func testIntegrationDocNamesEveryToolAndCommand() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let doc = try String(contentsOf: root.appendingPathComponent("docs/AGENTS-INTEGRATION.md"), encoding: .utf8)

        for tool in MCPServer.toolNames {
            XCTAssertTrue(doc.contains("`\(tool)`"), "Missing MCP tool: \(tool)")
        }
        for command in AgentCLI.commands.sorted() {
            XCTAssertTrue(doc.contains("`\(command)`"), "Missing CLI command: \(command)")
        }
        XCTAssertFalse(doc.contains("All three tools"))
        XCTAssertTrue(doc.contains("Only the first three tools declare an `outputSchema`"))
    }
}
