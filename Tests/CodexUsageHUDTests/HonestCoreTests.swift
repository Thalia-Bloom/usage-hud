import XCTest
@testable import CodexUsageHUD

/// The trust fixes of Oct 21, 2026: an expired Claude Code token is never
/// sent and recovers by itself, every number says how old it is, and local
/// model tokens are counted from the log Ollama actually writes.
final class HonestCoreTests: XCTestCase {
    private func tempDir() throws -> URL {
        let url = TestTemporaryDirectory.root.appendingPathComponent("hud-honest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - Claude sign-in

    func testExpiredTokenIsNeverSentAndRecoversWhenRenewed() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent(UsagePaths.claudeNativeUsageFilename)
        var now = Date(timeIntervalSince1970: 1_790_000_000)
        var expires = now.addingTimeInterval(-3600)
        var sent = 0
        let reader = ClaudeNativeUsageReader(
            stateFile: file,
            sharedCooldownFile: nil,
            now: { now },
            timeZone: TimeZone(identifier: "America/Los_Angeles")!,
            credential: { "fake-test-token" },
            transport: { _ in
                sent += 1
                let body: [String: Any] = ["limits": [["kind": "weekly_all", "percent": 3, "resets_at": "2026-10-28T23:00:00+00:00"]]]
                return .success(ClaudeNativeHTTP.Response(statusCode: 200, headers: [:],
                                                         body: try! JSONSerialization.data(withJSONObject: body)))
            },
            credentialExpiresAt: { expires }
        )

        _ = reader.run(trigger: .scheduled)
        XCTAssertEqual(sent, 0, "an expired token must not reach the endpoint")
        let doc = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let status = try XCTUnwrap(doc["officialUsageStatus"] as? [String: Any])
        XCTAssertEqual(status["status"] as? String, "token_expired")
        XCTAssertTrue((status["message"] as? String ?? "").contains("Open Claude Code once"))

        // Still expired a minute later: still nothing sent.
        now = now.addingTimeInterval(61)
        _ = reader.run(trigger: .scheduled)
        XCTAssertEqual(sent, 0)

        // Claude Code ran and renewed it: the next scheduled check fetches.
        expires = now.addingTimeInterval(8 * 3600)
        now = now.addingTimeInterval(61)
        _ = reader.run(trigger: .scheduled)
        XCTAssertEqual(sent, 1)
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual((after["officialUsageStatus"] as? [String: Any])?["status"] as? String, "ok")
    }

    func testExpiryIsReadFromTheKeychainValueWithoutTheToken() {
        let value = Data(#"{"claudeAiOauth":{"accessToken":"x","expiresAt":1790000000000}}"#.utf8)
        XCTAssertEqual(ClaudeNativeCredential.expiresAt(fromKeychainValue: value),
                       Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertNil(ClaudeNativeCredential.expiresAt(fromKeychainValue: Data(#"{"claudeAiOauth":{}}"#.utf8)))
    }

    func testExpiredTokenTellsTheFixNotSignInAgain() throws {
        let now = Date()
        let json = """
        {"provider":"claude","capturedAt":"\(ISO8601DateFormatter().string(from: now))",
         "week":{"label":"Weekly","usedPct":3,"eventAt":"\(ISO8601DateFormatter().string(from: now.addingTimeInterval(-7200)))"},
         "officialUsageStatus":{"status":"token_expired","message":"Open Claude Code once"}}
        """
        let snap = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        let fresh = UsageInsights.laneFreshness(for: snap, now: now)
        XCTAssertEqual(fresh.issue, "open Claude Code once")
        XCTAssertTrue(fresh.needsAttention)
        let header = HeaderStatus.make(lanes: [.init(name: "Claude", freshness: fresh)])
        XCTAssertEqual(header.text, "Claude · open Claude Code once")
    }

    // MARK: - Freshness

    func testLiveReadingsStillSayHowOldTheyAre() {
        let now = Date()
        let live = LaneFreshness.make(readAt: now.addingTimeInterval(-180), oldAfter: 3600, now: now)
        XCTAssertEqual(live.state, .live)
        XCTAssertEqual(live.note, "3m ago")
        let recent = LaneFreshness.make(readAt: now.addingTimeInterval(-11 * 60), oldAfter: 3600, now: now)
        XCTAssertEqual(recent.state, .recent, "past 10 minutes a reading is no longer live")
    }

    // MARK: - Local models

    private let logA = """
    time=2026-10-21T20:55:30.525-07:00 level=INFO source=images.go msg="template selection" model=registry.ollama.ai/library/gemma4:e4b
    slot print_timing: id  0 | task 0 | prompt eval time =     324.09 ms /    51 tokens (    6.35 ms per token,   157 tokens per second)
    slot print_timing: id  0 | task 0 |        eval time =    1208.91 ms /    30 tokens (   41.69 ms per token,    23 tokens per second)
    [GIN] 2026/10/21 - 20:56:44 | 200 |         1m13s |       127.0.0.1 | POST     "/api/chat"

    """

    func testLocalLogIsFollowedIncrementallyAndRotationIsNotDoubleCounted() throws {
        let dir = try tempDir()
        let log = dir.appendingPathComponent("server.log")
        try logA.write(to: log, atomically: false, encoding: .utf8)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let parsed = try XCTUnwrap(LocalModelUsageReader.parse(logs: [logA], now: Date(timeIntervalSince1970: 1_792_558_800), calendar: calendar))
        XCTAssertEqual(parsed.totalTokens, 81)
        XCTAssertEqual(parsed.modelTokens["gemma4:e4b"], 81)

        // Appended lines, including a half-written one, are picked up as they land.
        var cursor = OllamaLogCursor(calendar: calendar)
        XCTAssertEqual(cursor.feed(logA).count, 1)
        let more = """
        slot print_timing: id  0 | task 1 | prompt eval time =  10 ms /  100 tokens
        slot print_timing: id  0 | task 1 |        eval time =  10 ms /   20 tokens
        [GIN] 2026/10/21 - 21:00:00 | 200 |   2s |       127.0.0.1 | POST     "/v1/chat/completions"

        """
        let requests = cursor.feed(more)
        XCTAssertEqual(requests.map { $0.prompt + $0.generated }, [120])
        XCTAssertEqual(requests.first?.model, "gemma4:e4b")
    }

    func testRunningOllamaWithNoRequestsShowsZeroNotStartOllama() {
        let snap = LocalModelUsageReader.snapshot(from: OllamaTokenSummary(), sources: [], partial: false, running: true)
        XCTAssertEqual(snap.session?.todayTotal, 0)
        XCTAssertEqual(snap.provider, "local")
    }
}
