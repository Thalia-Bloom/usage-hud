import XCTest
@testable import CodexUsageHUD

private typealias F = AgentFixtures

final class MCPServerTests: XCTestCase {
    private func server(_ snapshots: [UsageSnapshot] = F.fleet) -> MCPServer {
        MCPServer(version: "9.9.9", summaryProvider: { F.summary(snapshots) })
    }

    private func send(_ server: MCPServer, _ message: [String: Any]) throws -> [String: Any] {
        let line = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
        let reply = try XCTUnwrap(server.handle(line: line), "no reply to \(message["method"] ?? "?")")
        XCTAssertFalse(reply.contains("\n"), "stdio messages must not contain newlines")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    }

    private func request(_ id: Int, _ method: String, _ params: [String: Any]? = nil) -> [String: Any] {
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }
        return message
    }

    private let modernMeta: [String: Any] = [
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": [String: Any](),
        "io.modelcontextprotocol/clientInfo": ["name": "test", "version": "1"],
    ]

    private func initialize(_ s: MCPServer, version: String = "2025-11-25") throws -> [String: Any] {
        try send(s, request(1, "initialize", ["protocolVersion": version, "capabilities": [String: Any](),
                                              "clientInfo": ["name": "test", "version": "1"]]))
    }

    // MARK: Legacy lifecycle

    func testInitializeNegotiatesTheVersion() throws {
        for version in MCPServer.legacyVersions {
            let reply = try initialize(server(), version: version)
            let result = try XCTUnwrap(reply["result"] as? [String: Any])
            XCTAssertEqual(result["protocolVersion"] as? String, version)
            XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "usage-hud")
            XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
            XCTAssertNotNil(result["instructions"] as? String)
        }
        let unknown = try initialize(server(), version: "1999-01-01")
        XCTAssertEqual((unknown["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-11-25")
    }

    func testNotificationsAndClientResponsesGetNoReply() {
        let s = server()
        XCTAssertNil(s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertNil(s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"#))
        XCTAssertNil(s.handle(line: #"{"jsonrpc":"2.0","id":9,"result":{}}"#))
        XCTAssertNil(s.handle(line: "   "))
    }

    func testToolsListDescribesFiveReadOnlyTools() throws {
        let s = server()
        _ = try initialize(s)
        let reply = try send(s, request(2, "tools/list"))
        let tools = try XCTUnwrap((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.map { $0["name"] as? String }, ["usage_status", "which_plan_has_room", "lane_detail", "spend_summary", "recent_activity"])
        for tool in tools {
            XCTAssertEqual((tool["inputSchema"] as? [String: Any])?["type"] as? String, "object")
            // The limit tools declare output schemas; spend and activity
            // return structured JSON without one.
            if ["usage_status", "which_plan_has_room", "lane_detail"].contains(tool["name"] as? String) {
                XCTAssertNotNil(tool["outputSchema"])
            }
            XCTAssertEqual((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)
            XCTAssertEqual((tool["annotations"] as? [String: Any])?["openWorldHint"] as? Bool, false)
            XCTAssertGreaterThan((tool["description"] as? String)?.count ?? 0, 80)
        }
        XCTAssertEqual(((tools[2]["inputSchema"] as? [String: Any])?["required"] as? [String]), ["provider"])
    }

    func testOldProtocolVersionsGetNoOutputSchemaOrStructuredContent() throws {
        let s = server()
        _ = try initialize(s, version: "2025-03-26")
        let tools = try XCTUnwrap(((try send(s, request(2, "tools/list")))["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertTrue(tools.allSatisfy { $0["outputSchema"] == nil })
        let call = try XCTUnwrap(try send(s, request(3, "tools/call", ["name": "usage_status", "arguments": [String: Any]()]))["result"] as? [String: Any])
        XCTAssertNil(call["structuredContent"])
        XCTAssertEqual((call["content"] as? [[String: Any]])?.count, 2)
    }

    func testUsageStatusReturnsTheSchemaAndMatchingText() throws {
        let s = server()
        _ = try initialize(s)
        let result = try XCTUnwrap(try send(s, request(3, "tools/call", ["name": "usage_status", "arguments": [String: Any]()]))["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(MiniSchemaValidator.errors(structured, schema: AgentSchema.summary), [])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertTrue((content[0]["text"] as? String)?.hasPrefix("GO  Claude: clear to build.") == true)
        // Back-compat text block carries the same JSON.
        let echoed = try JSONSerialization.jsonObject(with: Data((content[1]["text"] as? String ?? "").utf8)) as? [String: Any]
        XCTAssertEqual(echoed.map { NSDictionary(dictionary: $0) }, NSDictionary(dictionary: structured))
    }

    func testWhichPlanHasRoom() throws {
        let s = server()
        _ = try initialize(s)
        let result = try XCTUnwrap(try send(s, request(4, "tools/call", ["name": "which_plan_has_room"]))["result"] as? [String: Any])
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(MiniSchemaValidator.errors(structured, schema: AgentSchema.roomAdvice), [])
        XCTAssertEqual((structured["roomNow"] as? [String: Any])?["lane"] as? String, "grok")
        XCTAssertEqual((structured["verdict"] as? [String: Any])?["mode"] as? String, "GO")
        XCTAssertEqual(((result["content"] as? [[String: Any]])?.first?["text"] as? String), structured["advice"] as? String)
    }

    func testLaneDetailAndItsToolErrors() throws {
        let s = server()
        _ = try initialize(s)
        let found = try XCTUnwrap(try send(s, request(5, "tools/call", ["name": "lane_detail", "arguments": ["provider": "Claude Code"]]))["result"] as? [String: Any])
        XCTAssertEqual(found["isError"] as? Bool, false)
        let structured = try XCTUnwrap(found["structuredContent"] as? [String: Any])
        XCTAssertEqual(MiniSchemaValidator.errors(structured, schema: AgentSchema.laneDetail), [])
        XCTAssertEqual((structured["lane"] as? [String: Any])?["provider"] as? String, "claude")

        for arguments in [["provider": "nope"], ["provider": "not-a-lane"], [String: String]()] {
            let result = try XCTUnwrap(try send(s, request(6, "tools/call", ["name": "lane_detail", "arguments": arguments]))["result"] as? [String: Any])
            XCTAssertEqual(result["isError"] as? Bool, true, "\(arguments)")
            XCTAssertNil(result["structuredContent"])
        }
    }

    func testProtocolErrors() throws {
        let s = server()
        _ = try initialize(s)
        let unknownTool = try send(s, request(7, "tools/call", ["name": "delete_everything"]))
        XCTAssertEqual((unknownTool["error"] as? [String: Any])?["code"] as? Int, -32602)
        let unknownMethod = try send(s, request(8, "resources/list"))
        XCTAssertEqual((unknownMethod["error"] as? [String: Any])?["code"] as? Int, -32601)
        let parse = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data((s.handle(line: "{not json") ?? "").utf8)) as? [String: Any])
        XCTAssertEqual((parse["error"] as? [String: Any])?["code"] as? Int, -32700)
        XCTAssertTrue(parse["id"] is NSNull)
        let noMethod = try send(s, ["jsonrpc": "2.0", "id": 9])
        XCTAssertEqual((noMethod["error"] as? [String: Any])?["code"] as? Int, -32600)
        let ping = try send(s, request(10, "ping"))
        XCTAssertNotNil(ping["result"] as? [String: Any])
        XCTAssertEqual(ping["id"] as? Int, 10)
    }

    func testStringIdsAreEchoed() throws {
        let reply = try send(server(), ["jsonrpc": "2.0", "id": "abc-1", "method": "tools/list"])
        XCTAssertEqual(reply["id"] as? String, "abc-1")
    }

    func testBatchesGetAnArrayReply() throws {
        let s = server()
        let line = #"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":2,"method":"tools/list"}]"#
        let reply = try XCTUnwrap(s.handle(line: line))
        let array = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [[String: Any]])
        XCTAssertEqual(array.compactMap { $0["id"] as? Int }, [1, 2])
    }

    // MARK: Modern (2026-07-28) stateless requests

    func testServerDiscover() throws {
        let reply = try send(server(), request(1, "server/discover", ["_meta": modernMeta]))
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["resultType"] as? String, "complete")
        XCTAssertEqual(result["supportedVersions"] as? [String], MCPServer.supportedVersions)
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        XCTAssertEqual(result["cacheScope"] as? String, "public")
        XCTAssertNotNil(result["ttlMs"] as? Int)
        let meta = try XCTUnwrap(result["_meta"] as? [String: Any])
        XCTAssertEqual((meta["io.modelcontextprotocol/serverInfo"] as? [String: Any])?["name"] as? String, "usage-hud")
    }

    func testModernToolCallsNeedNoHandshake() throws {
        let s = server()
        let list = try XCTUnwrap(try send(s, request(2, "tools/list", ["_meta": modernMeta]))["result"] as? [String: Any])
        XCTAssertEqual(list["resultType"] as? String, "complete")
        XCTAssertNotNil(list["ttlMs"])
        XCTAssertEqual(list["cacheScope"] as? String, "public")
        let call = try XCTUnwrap(try send(s, request(3, "tools/call", ["name": "usage_status", "_meta": modernMeta]))["result"] as? [String: Any])
        XCTAssertEqual(call["resultType"] as? String, "complete")
        XCTAssertNotNil(call["structuredContent"])
        XCTAssertNotNil((call["_meta"] as? [String: Any])?["io.modelcontextprotocol/serverInfo"])
    }

    func testModernVersionAndMetaErrors() throws {
        let s = server()
        var future = modernMeta
        future["io.modelcontextprotocol/protocolVersion"] = "2099-01-01"
        let unsupported = try XCTUnwrap(try send(s, request(1, "tools/list", ["_meta": future]))["error"] as? [String: Any])
        XCTAssertEqual(unsupported["code"] as? Int, -32022)
        XCTAssertEqual((unsupported["data"] as? [String: Any])?["supported"] as? [String], MCPServer.supportedVersions)
        XCTAssertEqual((unsupported["data"] as? [String: Any])?["requested"] as? String, "2099-01-01")

        var noCaps = modernMeta
        noCaps.removeValue(forKey: "io.modelcontextprotocol/clientCapabilities")
        let missing = try XCTUnwrap(try send(s, request(2, "tools/list", ["_meta": noCaps]))["error"] as? [String: Any])
        XCTAssertEqual(missing["code"] as? Int, -32602)

        let bareDiscover = try XCTUnwrap(try send(s, request(3, "server/discover"))["error"] as? [String: Any])
        XCTAssertEqual(bareDiscover["code"] as? Int, -32602)

        let modernPing = try XCTUnwrap(try send(s, request(4, "ping", ["_meta": modernMeta]))["error"] as? [String: Any])
        XCTAssertEqual(modernPing["code"] as? Int, -32601)
    }

    // MARK: Transport loop

    func testRunLoopAnswersEachRequestOnItsOwnLineAndStopsAtEOF() {
        var input = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"which_plan_has_room","arguments":{}}}"#,
            "",
        ][...]
        var output: [String] = []
        server().run(readLine: { input.popFirst() }, write: { output.append($0) })
        XCTAssertEqual(output.count, 3)
        XCTAssertTrue(output.allSatisfy { !$0.contains("\n") })
        XCTAssertEqual(output.compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["id"] as? Int
        }, [1, 2, 3])
    }
}
