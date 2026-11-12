import XCTest
@testable import CodexUsageHUD

/// The in-app Claude reader: parser parity with the Python fetch, the safety
/// rules (cooldowns, throttle, token handling), and writer coexistence.
/// No test touches the Keychain or the network.
final class ClaudeNativeUsageTests: XCTestCase {
    private let pacific = TimeZone(identifier: "America/Los_Angeles")!
    private let fakeToken = "test-token-not-real-0000"

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func tempDir(_ name: String) throws -> URL {
        let url = TestTemporaryDirectory.root.appendingPathComponent("hud-claude-native-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func fixtureBody() throws -> [String: Any] {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("fixtures/claude-oauth-usage-sample.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decode(_ document: [String: Any]) throws -> UsageSnapshot {
        let data = try JSONSerialization.data(withJSONObject: document)
        return try JSONDecoder().decode(UsageSnapshot.self, from: data)
    }

    /// The endpoint's shape: microseconds, numeric offset, a fraction early.
    private func apiStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'+00:00'"
        return formatter.string(from: date.addingTimeInterval(-0.36))
    }

    private func liveBody(session: Double, week: Double, fable: Double?, now: Date) -> [String: Any] {
        var limits: [[String: Any]] = [
            ["kind": "session", "percent": session, "resets_at": apiStamp(now.addingTimeInterval(2 * 3600))],
            ["kind": "weekly_all", "percent": week, "resets_at": apiStamp(now.addingTimeInterval(5 * 86_400))],
        ]
        if let fable {
            limits.append(["kind": "weekly_scoped", "percent": fable, "resets_at": apiStamp(now.addingTimeInterval(5 * 86_400)),
                           "scope": ["model": ["id": NSNull(), "display_name": "Fable"], "surface": NSNull()]])
        }
        return ["limits": limits]
    }

    private func okResponse(_ body: [String: Any]) -> Result<ClaudeNativeHTTP.Response, Error> {
        .success(ClaudeNativeHTTP.Response(statusCode: 200, headers: [:], body: try! JSONSerialization.data(withJSONObject: body)))
    }

    private final class Recorder {
        var requests: [URLRequest] = []
        var responses: [Result<ClaudeNativeHTTP.Response, Error>] = []
        var credentialReads = 0
        var token: String?
    }

    private func makeReader(file: URL, clock: @escaping () -> Date, recorder: Recorder) -> ClaudeNativeUsageReader {
        ClaudeNativeUsageReader(
            stateFile: file,
            sharedCooldownFile: nil,
            now: clock,
            timeZone: pacific,
            credential: { recorder.credentialReads += 1; return recorder.token },
            transport: { request in
                recorder.requests.append(request)
                return recorder.responses.isEmpty ? .failure(URLError(.notConnectedToInternet)) : recorder.responses.removeFirst()
            }
        )
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    // MARK: - Parser parity with bin/bloom-usage-fetch-claude-official

    func testParserMatchesPythonOnRecordedFixture() throws {
        let captured = Date(timeIntervalSince1970: 1_790_000_000.123)
        let payload = try XCTUnwrap(ClaudeOfficialUsageParser.buildPayload(body: fixtureBody(), capturedAt: captured, timeZone: pacific))
        let iso = ClaudeOfficialUsageParser.isoZms(captured)
        XCTAssertEqual(iso, "2026-09-21T14:13:20.123Z")
        XCTAssertEqual(payload["sourceKind"] as? String, "official_api")
        XCTAssertEqual(payload["confidence"] as? String, "official")
        XCTAssertEqual(payload["source"] as? String, "claude-code-official-usage-api")
        XCTAssertEqual(payload["capturedAt"] as? String, iso)
        XCTAssertEqual(payload["eventAt"] as? String, iso)
        XCTAssertEqual(payload["updatedAt"] as? String, iso)

        // Values the Python fetch writes for this fixture under TZ=America/Los_Angeles.
        let session = try XCTUnwrap(payload["currentSession"] as? [String: Any])
        XCTAssertEqual(session["label"] as? String, "5-hour limit")
        XCTAssertEqual((session["usedPct"] as? NSNumber)?.doubleValue, 40)
        XCTAssertEqual(session["resetAt"] as? String, "2026-09-03T09:20:00.000Z")
        XCTAssertEqual(session["resetLabel"] as? String, "2:20 AM")
        XCTAssertEqual(session["eventAt"] as? String, iso)

        let week = try XCTUnwrap(payload["week"] as? [String: Any])
        XCTAssertEqual(week["label"] as? String, "Weekly · all models")
        XCTAssertEqual((week["usedPct"] as? NSNumber)?.doubleValue, 9)
        XCTAssertEqual(week["resetAt"] as? String, "2026-09-09T23:00:00.000Z")
        XCTAssertEqual(week["resetLabel"] as? String, "Sep 9 4 PM")

        let fable = try XCTUnwrap(payload["weekFable"] as? [String: Any])
        XCTAssertEqual(fable["label"] as? String, "Fable weekly")
        XCTAssertEqual((fable["usedPct"] as? NSNumber)?.doubleValue, 8)
        XCTAssertEqual(fable["resetAt"] as? String, "2026-09-09T23:00:00.000Z")
        XCTAssertEqual(fable["resetLabel"] as? String, "Sep 9 4 PM")
        XCTAssertEqual(fable["capturedAt"] as? String, iso)

        let skills = try XCTUnwrap(payload["skills"] as? [[String: Any]])
        XCTAssertEqual(skills.count, 1)
        XCTAssertEqual(skills.first?["name"] as? String, "Limit · Fable weekly")
        XCTAssertEqual((payload["contributors"] as? [Any])?.count, 0)

        let official = try XCTUnwrap(payload["officialUsage"] as? [String: Any])
        XCTAssertEqual(official["source"] as? String, "api")
        XCTAssertEqual((official["limits"] as? [Any])?.count, 3)
        let extra = try XCTUnwrap(official["extraUsage"] as? [String: Any])
        XCTAssertEqual(extra["enabled"] as? Bool, false)
        XCTAssertTrue(extra["monthlyLimit"] is NSNull)

        // And the app decodes it as the same lane the Python file produces.
        let snapshot = try decode(payload)
        XCTAssertEqual(snapshot.provider, "claude")
        XCTAssertEqual(snapshot.currentSession?.usedPct, 40)
        XCTAssertEqual(snapshot.week?.usedPct, 9)
        XCTAssertEqual(snapshot.weekFable?.usedPct, 8)
        XCTAssertEqual(UsageInsights.confidence(snapshot).label.lowercased(), "official")
    }

    func testParserFallsBackToFiveHourAndSevenDay() throws {
        let body: [String: Any] = [
            "five_hour": ["utilization": 15, "resets_at": "2026-09-03T09:19:59.000000+00:00"],
            "seven_day": ["utilization": 22, "resets_at": "2026-09-09T22:59:59.000000+00:00"],
            "limits": NSNull(),
        ]
        let payload = try XCTUnwrap(ClaudeOfficialUsageParser.buildPayload(body: body, capturedAt: Date(timeIntervalSince1970: 1_790_000_000), timeZone: pacific))
        XCTAssertEqual(((payload["currentSession"] as? [String: Any])?["usedPct"] as? NSNumber)?.doubleValue, 15)
        XCTAssertEqual((payload["week"] as? [String: Any])?["resetAt"] as? String, "2026-09-09T23:00:00.000Z")
        XCTAssertNil(payload["weekFable"])
        XCTAssertNil(payload["skills"])
        let raw = try XCTUnwrap((payload["officialUsage"] as? [String: Any])?["limits"] as? [[String: Any]])
        XCTAssertEqual(raw.map { $0["kind"] as? String }, ["session", "weekly_all"])
    }

    func testOtherScopedWeeklyLimitsBecomeSkillsNotFableRows() throws {
        let body: [String: Any] = ["limits": [
            ["kind": "session", "percent": 5, "resets_at": "2026-09-03T09:19:59.000000+00:00", "scope": NSNull()],
            ["kind": "weekly_all", "percent": 6, "resets_at": "2026-09-09T22:59:59.000000+00:00", "scope": NSNull()],
            ["kind": "weekly_scoped", "percent": 7, "resets_at": "2026-09-09T22:59:59.000000+00:00",
             "scope": ["model": ["display_name": "Sonnet"]]],
        ]]
        let payload = try XCTUnwrap(ClaudeOfficialUsageParser.buildPayload(body: body, capturedAt: Date(), timeZone: pacific))
        XCTAssertNil(payload["weekFable"])
        let skills = try XCTUnwrap(payload["skills"] as? [[String: Any]])
        XCTAssertEqual(skills.map { $0["name"] as? String }, ["Limit · Sonnet weekly"])
    }

    func testParserReturnsNilWithoutAnyWindow() {
        for body: [String: Any] in [[:], ["limits": [Any]()], ["five_hour": NSNull(), "seven_day": [String: Any]()], ["limits": [["kind": "other"]]]] {
            XCTAssertNil(ClaudeOfficialUsageParser.buildPayload(body: body, capturedAt: Date(), timeZone: pacific), "\(body)")
        }
    }

    func testResetTimesRoundToTheMinute() {
        func iso(_ raw: Any?) -> String? { ClaudeOfficialUsageParser.parseResetsAt(raw).map(ClaudeOfficialUsageParser.isoZms) }
        XCTAssertEqual(iso("2026-09-03T09:19:59.816508+00:00"), "2026-09-03T09:20:00.000Z")
        XCTAssertEqual(iso("2026-10-01T07:50:00.239039+00:00"), "2026-10-01T07:50:00.000Z")
        XCTAssertEqual(iso("2026-10-07T23:00:00+00:00"), "2026-10-07T23:00:00.000Z")
        XCTAssertEqual(iso("2026-10-07T22:59:59.9Z"), "2026-10-07T23:00:00.000Z")
        XCTAssertEqual(iso("2026-10-07T15:59:59.700-07:00"), "2026-10-07T23:00:00.000Z")
        XCTAssertEqual(iso("2026-10-07T23:00:29"), "2026-10-07T23:00:00.000Z")
        XCTAssertNil(iso("soon"))
        XCTAssertNil(iso(""))
        XCTAssertNil(iso(NSNull()))
        XCTAssertNil(iso(1_790_000_000))
    }

    func testResetLabelsUseLocalTimeLikeThePythonFetch() {
        let utc = TimeZone(identifier: "UTC")!
        let midnight = Date(timeIntervalSince1970: 1_767_225_900) // 2026-01-01 00:05 UTC
        XCTAssertEqual(ClaudeOfficialUsageParser.fiveHourResetLabel(midnight, timeZone: utc), "12:05 AM")
        XCTAssertEqual(ClaudeOfficialUsageParser.weekResetLabel(midnight, timeZone: utc), "Jan 1 12 AM")
        let noon = midnight.addingTimeInterval(12 * 3600 - 5 * 60) // 12:00 UTC
        XCTAssertEqual(ClaudeOfficialUsageParser.fiveHourResetLabel(noon, timeZone: utc), "12:00 PM")
        XCTAssertEqual(ClaudeOfficialUsageParser.weekResetLabel(noon, timeZone: pacific), "Jan 1 4 AM")
    }

    // MARK: - Credential and request

    func testCredentialReadsEnvFirstThenKeychainExactlyLikeThePython() throws {
        var calls: [[String]] = []
        let keychainValue = Data(#"{"claudeAiOauth":{"accessToken":"kc-token","refreshToken":"never-used","expiresAt":1}}"#.utf8)
        let fromEnv = ClaudeNativeCredential.resolve(env: ["CLAUDE_CODE_OAUTH_TOKEN": "env-token"], account: "me") { calls.append($0); return nil }
        XCTAssertEqual(fromEnv, "env-token")
        XCTAssertTrue(calls.isEmpty, "env token must short-circuit the Keychain")

        let fromKeychain = ClaudeNativeCredential.resolve(env: [:], account: "me") { args in
            calls.append(args)
            return .init(status: 0, stdout: keychainValue)
        }
        XCTAssertEqual(fromKeychain, "kc-token")
        XCTAssertEqual(calls.last, ["find-generic-password", "-s", "Claude Code-credentials", "-a", "me", "-w"])

        XCTAssertNil(ClaudeNativeCredential.resolve(env: [:], account: "me") { _ in .init(status: 44, stdout: Data()) })
        XCTAssertNil(ClaudeNativeCredential.resolve(env: [:], account: "me") { _ in .init(status: 0, stdout: Data("not json".utf8)) })
        XCTAssertNil(ClaudeNativeCredential.resolve(env: [:], account: "me") { _ in .init(status: 0, stdout: Data(#"{"claudeAiOauth":{}}"#.utf8)) })
        XCTAssertNil(ClaudeNativeCredential.resolve(env: [:], account: "me") { _ in nil }, "a timed-out lookup is no credential")
        XCTAssertEqual(ClaudeNativeCredential.lastLookupOutcome, .keychainLocked)
        XCTAssertNil(ClaudeNativeCredential.resolve(env: [:], account: nil) { _ in .init(status: 0, stdout: keychainValue) })

        // Service-only Keychain fallback when account name differs, and read-only .credentials.json fallback.
        let svcFallback = ClaudeNativeCredential.resolve(env: [:], account: "wrong") { args in
            args.contains("-a") ? .init(status: 44, stdout: Data()) : .init(status: 0, stdout: keychainValue)
        }
        XCTAssertEqual(svcFallback, "kc-token")
        let credFile = try tempDir("creds").appendingPathComponent(".credentials.json")
        try Data(#"{"claudeAiOauth":{"accessToken":"file-token"}}"#.utf8).write(to: credFile)
        XCTAssertEqual(ClaudeNativeCredential.resolve(env: [:], account: "me", credentialsFiles: [credFile]) { _ in .init(status: 44, stdout: Data()) }, "file-token")
        XCTAssertEqual(ClaudeNativeCredential.lastLookupOutcome, .credentialsFile)
    }

    func testRequestSendsTheSameHeadersAsThePython() {
        let request = ClaudeNativeHTTP.request(token: fakeToken)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(fakeToken)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 10)
    }

    func testHTTPOutcomesMapToTheSameStatusesAsThePython() {
        func response(_ code: Int, _ headers: [String: String] = [:], _ body: String = "{}") -> Result<ClaudeNativeHTTP.Response, Error> {
            .success(.init(statusCode: code, headers: headers, body: Data(body.utf8)))
        }
        if case .ok(let body) = ClaudeNativeHTTP.classify(response(200, [:], #"{"limits":[]}"#)) {
            XCTAssertNotNil(body["limits"])
        } else { XCTFail("200 should parse") }
        if case .rateLimited(let after) = ClaudeNativeHTTP.classify(response(429, ["Retry-After": "120"])) {
            XCTAssertEqual(after, "120")
        } else { XCTFail("429 should be rate_limited") }
        for code in [401, 403] {
            guard case .unauthorized = ClaudeNativeHTTP.classify(response(code)) else { return XCTFail("\(code) should be unauthorized") }
        }
        if case .offline(let detail) = ClaudeNativeHTTP.classify(response(500)) {
            XCTAssertEqual(detail, "HTTP 500")
        } else { XCTFail("500 should be offline") }
        if case .offline(let detail) = ClaudeNativeHTTP.classify(.failure(URLError(.notConnectedToInternet))) {
            XCTAssertFalse(detail.isEmpty)
            XCTAssertNotEqual(detail, "Usage endpoint unreachable.")
        } else { XCTFail("a transport error should be offline") }
        if case .offline(let detail) = ClaudeNativeHTTP.classify(response(200, [:], "<html>")) {
            XCTAssertTrue(detail.contains("invalid JSON"), detail)
        } else { XCTFail("bad JSON should be offline") }
        if case .offline(let detail) = ClaudeNativeHTTP.classify(response(200, [:], "[1,2]")) {
            XCTAssertTrue(detail.contains("not an object"), detail)
        } else { XCTFail("a JSON array should be offline") }
    }

    // MARK: - Throttle and cooldowns

    func testThrottleAllowsOneScheduledFetchPerFiveMinutes() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertNil(ClaudeNativeThrottle.skipReason(trigger: .scheduled, now: now, lastAttemptAt: nil, lastStatus: nil, retryAt: nil))
        XCTAssertNotNil(ClaudeNativeThrottle.skipReason(trigger: .scheduled, now: now, lastAttemptAt: now.addingTimeInterval(-299), lastStatus: "ok", retryAt: nil))
        XCTAssertNil(ClaudeNativeThrottle.skipReason(trigger: .scheduled, now: now, lastAttemptAt: now.addingTimeInterval(-300), lastStatus: "ok", retryAt: nil))
        XCTAssertNotNil(ClaudeNativeThrottle.skipReason(trigger: .scheduled, now: now, lastAttemptAt: now.addingTimeInterval(-700), lastStatus: "ok", retryAt: nil,
                                                        sharedCooldownUntil: now.addingTimeInterval(30)),
                        "the Python fetch's shared cooldown file also holds scheduled fetches")
    }

    func testManualRefreshBypassesTheIntervalButKeepsTheFloorAnd429Window() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertNotNil(ClaudeNativeThrottle.skipReason(trigger: .manual, now: now, lastAttemptAt: now.addingTimeInterval(-59), lastStatus: "ok", retryAt: nil))
        XCTAssertNil(ClaudeNativeThrottle.skipReason(trigger: .manual, now: now, lastAttemptAt: now.addingTimeInterval(-61), lastStatus: "ok", retryAt: nil))
        // A durable failure (user may have just signed in) can be retried by hand, even inside the 60s floor.
        XCTAssertNil(ClaudeNativeThrottle.skipReason(trigger: .manual, now: now, lastAttemptAt: now.addingTimeInterval(-12), lastStatus: "no_credential",
                                                     retryAt: now.addingTimeInterval(480)))
        XCTAssertNil(ClaudeNativeThrottle.skipReason(trigger: .manual, now: now, lastAttemptAt: now.addingTimeInterval(-120), lastStatus: "unauthorized",
                                                     retryAt: now.addingTimeInterval(480)))
        XCTAssertNotNil(ClaudeNativeThrottle.skipReason(trigger: .scheduled, now: now, lastAttemptAt: now.addingTimeInterval(-700), lastStatus: "unauthorized",
                                                        retryAt: now.addingTimeInterval(1)))
        // A 429 window holds even a manual Refresh or Set up.
        for trigger in [ClaudeNativeTrigger.manual, .setup] {
            XCTAssertNotNil(ClaudeNativeThrottle.skipReason(trigger: trigger, now: now, lastAttemptAt: now.addingTimeInterval(-120), lastStatus: "rate_limited",
                                                            retryAt: now.addingTimeInterval(60)))
        }
    }

    // MARK: - Reader end to end (fake transport, temp file)

    func testSuccessWritesAnOfficialSnapshotTheSetupCardAccepts() throws {
        let dir = try tempDir("success")
        let file = dir.appendingPathComponent(UsagePaths.claudeNativeUsageFilename)
        var now = Date(timeIntervalSince1970: 1_790_000_000)
        let recorder = Recorder()
        recorder.token = fakeToken
        recorder.responses = [okResponse(liveBody(session: 12, week: 9, fable: 3, now: now))]
        let reader = makeReader(file: file, clock: { now }, recorder: recorder)

        XCTAssertEqual(reader.run(trigger: .setup), .fetched(status: "ok", message: "Claude Code official usage API parsed."))
        XCTAssertEqual(recorder.requests.count, 1)
        let raw = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(raw.contains(fakeToken), "the token must never be written")
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let document = try readJSON(file)
        XCTAssertEqual(document["producer"] as? String, "usage-hud-app")
        XCTAssertEqual((document["officialUsageStatus"] as? [String: Any])?["status"] as? String, "ok")
        XCTAssertEqual((document["health"] as? [String: Any])?["verdict"] as? String, "fresh")
        XCTAssertEqual((document["week"] as? [String: Any])?["source"] as? String, "official")

        let snapshot = try XCTUnwrap(LaneSetupScoring.loadSnapshot(provider: "claude", stateDirectory: dir))
        XCTAssertEqual(snapshot.weekFable?.usedPct, 3)
        XCTAssertEqual(snapshot.officialUsageStatus?.status, "ok")
        XCTAssertFalse(snapshot.officialUsageStatus?.isWarning ?? true)
        let lane = LaneSetupScoring.result(provider: "claude", snapshot: snapshot, nodeAvailable: false, pythonAvailable: false, now: now)
        XCTAssertEqual(lane.line, "Claude ✓ 9% of the week used · official")

        // A scheduled tick inside five minutes does not call the endpoint.
        now = now.addingTimeInterval(240)
        if case .skipped = reader.run(trigger: .scheduled) {} else { XCTFail("should be throttled") }
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.credentialReads, 1, "a throttled tick must not read the Keychain")
    }

    func testUnauthorizedKeepsTheLastReadingAndCoolsDownTenMinutes() throws {
        let dir = try tempDir("unauthorized")
        let file = dir.appendingPathComponent(UsagePaths.claudeNativeUsageFilename)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var now = start
        let recorder = Recorder()
        recorder.token = fakeToken
        recorder.responses = [
            okResponse(liveBody(session: 12, week: 9, fable: 3, now: start)),
            .success(.init(statusCode: 401, headers: [:], body: Data())),
            okResponse(liveBody(session: 14, week: 10, fable: 3, now: start)),
        ]
        let reader = makeReader(file: file, clock: { now }, recorder: recorder)
        reader.run(trigger: .scheduled)

        now = start.addingTimeInterval(601)
        XCTAssertEqual(reader.run(trigger: .scheduled),
                       .fetched(status: "unauthorized", message: "Claude refused this sign-in. Open Claude Code and sign in again; this lane fills in by itself."))
        let failed = try readJSON(file)
        let status = try XCTUnwrap(failed["officialUsageStatus"] as? [String: Any])
        XCTAssertEqual(status["retryAt"] as? String, ClaudeOfficialUsageParser.isoZms(now.addingTimeInterval(600)))
        XCTAssertEqual((failed["health"] as? [String: Any])?["verdict"] as? String, "degraded")
        XCTAssertEqual((failed["providerHealth"] as? [String: Any])?["status"] as? String, "unauthorized")
        XCTAssertEqual(failed["capturedAt"] as? String, ClaudeOfficialUsageParser.isoZms(start), "a failure never freshens the old reading")
        let snapshot = try decode(failed)
        XCTAssertEqual(snapshot.week?.usedPct, 9)
        XCTAssertEqual(LaneSetupScoring.result(provider: "claude", snapshot: snapshot, nodeAvailable: false, pythonAvailable: false, now: now).line,
                       "Claude ✗ not signed in")
        XCTAssertTrue(headerHasHealthWarning(snapshot))

        // Scheduled ticks wait out the cooldown without touching the Keychain.
        now = start.addingTimeInterval(601 + 599)
        if case .skipped = reader.run(trigger: .scheduled) {} else { XCTFail("cooldown should hold") }
        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertEqual(recorder.credentialReads, 2)

        // Past the 10-minute cooldown, a scheduled tick with the SAME refused token skips the network (never hammers 401s).
        now = start.addingTimeInterval(601 + 601)
        guard case .fetched(status: "unauthorized", _) = reader.run(trigger: .scheduled) else { return XCTFail("expected same-stamp unauthorized") }
        XCTAssertEqual(recorder.requests.count, 2, "same refused token must never be re-sent on scheduled ticks")

        // Refresh retries a durable failure once past the 60-second floor.
        now = now.addingTimeInterval(61)
        XCTAssertEqual(reader.run(trigger: .manual), .fetched(status: "ok", message: "Claude Code official usage API parsed."))
        let recovered = try decode(readJSON(file))
        XCTAssertEqual(recovered.week?.usedPct, 10)
        XCTAssertNil(recovered.providerHealth, "a good reading clears the failure")
    }

    func testNoCredentialNeverCallsTheEndpoint() throws {
        let dir = try tempDir("nocred")
        let file = dir.appendingPathComponent(UsagePaths.claudeNativeUsageFilename)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let recorder = Recorder()
        let reader = makeReader(file: file, clock: { now }, recorder: recorder)
        XCTAssertEqual(reader.run(trigger: .setup),
                       .fetched(status: "no_credential", message: "Claude Code isn't signed in on this Mac. Open Claude Code and sign in; this lane fills in by itself."))
        XCTAssertTrue(recorder.requests.isEmpty)
        let snapshot = try XCTUnwrap(LaneSetupScoring.loadSnapshot(provider: "claude", stateDirectory: dir))
        XCTAssertNil(snapshot.week)
        XCTAssertEqual(LaneSetupScoring.result(provider: "claude", snapshot: snapshot, nodeAvailable: false, pythonAvailable: false, now: now).line,
                       "Claude ✗ not signed in")
    }

    func testRateLimitHonorsRetryAfterEvenForManualRefresh() throws {
        let dir = try tempDir("ratelimit")
        let file = dir.appendingPathComponent(UsagePaths.claudeNativeUsageFilename)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var now = start
        let recorder = Recorder()
        recorder.token = fakeToken
        recorder.responses = [.success(.init(statusCode: 429, headers: ["retry-after": "180"], body: Data()))]
        let reader = makeReader(file: file, clock: { now }, recorder: recorder)
        guard case .fetched(status: "rate_limited", _) = reader.run(trigger: .manual) else { return XCTFail("expected rate_limited") }
        let status = try XCTUnwrap(readJSON(file)["officialUsageStatus"] as? [String: Any])
        XCTAssertEqual(status["retryAt"] as? String, ClaudeOfficialUsageParser.isoZms(start.addingTimeInterval(180)))
        XCTAssertEqual((try readJSON(file)["health"] as? [String: Any])?["verdict"] as? String, "stale")
        now = start.addingTimeInterval(90)
        if case .skipped = reader.run(trigger: .manual) {} else { XCTFail("429 window must hold a manual refresh") }
        XCTAssertEqual(recorder.requests.count, 1)
    }

    func testOfflineAndUnparsedKeepTheHonestDetail() throws {
        let dir = try tempDir("offline")
        let file = dir.appendingPathComponent(UsagePaths.claudeNativeUsageFilename)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var now = start
        let recorder = Recorder()
        recorder.token = fakeToken
        recorder.responses = [
            .failure(URLError(.cannotFindHost)),
            .success(.init(statusCode: 200, headers: [:], body: Data(#"{"limits":[]}"#.utf8))),
        ]
        let reader = makeReader(file: file, clock: { now }, recorder: recorder)
        guard case .fetched(status: "offline", let message) = reader.run(trigger: .manual) else { return XCTFail("expected offline") }
        let expectedDetail = URLError(.cannotFindHost).localizedDescription
        XCTAssertEqual(message, "Usage endpoint unreachable: \(expectedDetail)")
        XCTAssertEqual((try readJSON(file)["officialUsageStatus"] as? [String: Any])?["detail"] as? String, expectedDetail)

        now = start.addingTimeInterval(61)
        XCTAssertEqual(reader.run(trigger: .manual), .fetched(status: "unparsed", message: "No official Claude usage parsed from the API response."))
    }

    func testFableRowOnlyPersistsForAccountsThatHadFable() throws {
        let dir = try tempDir("fable")
        let file = dir.appendingPathComponent(UsagePaths.claudeNativeUsageFilename)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var now = start
        let recorder = Recorder()
        recorder.token = fakeToken
        recorder.responses = [
            okResponse(liveBody(session: 1, week: 2, fable: nil, now: start)),
            okResponse(liveBody(session: 1, week: 2, fable: 4, now: start)),
            okResponse(liveBody(session: 1, week: 2, fable: nil, now: start)),
        ]
        let reader = makeReader(file: file, clock: { now }, recorder: recorder)
        reader.run(trigger: .manual)
        XCTAssertNil(try readJSON(file)["rateLimitExpired"], "no Fable on this account: no Fable row")

        now = start.addingTimeInterval(61)
        reader.run(trigger: .manual)
        XCTAssertNotNil(try readJSON(file)["weekFable"])

        now = start.addingTimeInterval(122)
        reader.run(trigger: .manual)
        let document = try readJSON(file)
        XCTAssertNil(document["weekFable"])
        XCTAssertEqual(document["rateLimitExpired"] as? [String], ["weekFable"])
        XCTAssertEqual(try decode(document).rateLimitExpired, ["weekFable"])
    }

    // MARK: - Writer coexistence

    func testNativeReaderStandsDownWheneverAnotherProducerOwnsTheLane() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func decide(isolated: Bool = false, connected: Bool = true, setUp: Bool = true, writer: Bool = false, shared: Date? = nil) -> ClaudeNativeCoexistence.Decision {
            ClaudeNativeCoexistence.decide(isolatedStateDir: isolated, claudeConnected: connected, setUpDone: setUp,
                                           writerInstalled: writer, sharedFileModifiedAt: shared, now: now)
        }
        XCTAssertEqual(decide(), .run)
        // The owner's Mac: the claude-writer LaunchAgent owns claude-usage.json.
        XCTAssertNotEqual(decide(writer: true), .run)
        XCTAssertNotEqual(decide(writer: true, shared: now.addingTimeInterval(-3600)), .run)
        // The statusline tap (or a manual Python fetch) wrote recently.
        XCTAssertNotEqual(decide(shared: now.addingTimeInterval(-5 * 60)), .run)
        XCTAssertEqual(decide(shared: now.addingTimeInterval(-16 * 60)), .run)
        XCTAssertNotEqual(decide(setUp: false), .run, "nothing runs before the buyer clicks Set up")
        XCTAssertNotEqual(decide(connected: false), .run)
        XCTAssertNotEqual(decide(isolated: true), .run)
    }

    func testNativeFileIsItsOwnCandidateAndTheNewestFileWins() throws {
        XCTAssertEqual(UsagePaths.usageFilenames(for: "claude"), ["claude-usage.json", "claude-usage-native.json"])
        XCTAssertEqual(UsagePaths.usageFilenames(for: "codex"), ["codex-usage.json"])
        XCTAssertTrue(UsagePaths.providerUsageCandidates("claude").contains { $0.lastPathComponent == "claude-usage-native.json" })
        XCTAssertFalse(UsagePaths.providerUsageCandidates("gemini").contains { $0.lastPathComponent == "claude-usage-native.json" })

        let dir = try tempDir("candidates")
        let shared = dir.appendingPathComponent("claude-usage.json")
        let native = dir.appendingPathComponent("claude-usage-native.json")
        try #"{"provider":"claude","week":{"usedPct":11}}"#.write(to: shared, atomically: true, encoding: .utf8)
        try #"{"provider":"claude","week":{"usedPct":22}}"#.write(to: native, atomically: true, encoding: .utf8)
        let fm = FileManager.default
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: native.path)
        XCTAssertEqual(LaneSetupScoring.loadSnapshot(provider: "claude", stateDirectory: dir)?.week?.usedPct, 11)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: shared.path)
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: native.path)
        XCTAssertEqual(LaneSetupScoring.loadSnapshot(provider: "claude", stateDirectory: dir)?.week?.usedPct, 22)

        var seen: [String] = []
        BackgroundRefreshService.waitForUsageFiles(
            providers: ["claude"], stateDirectory: dir, timeout: 1, pollInterval: 0.1,
            sleep: { _ in XCTFail("the native file alone should satisfy the wait") }, now: Date.init,
            fileExists: { seen.append($0.lastPathComponent); return $0.lastPathComponent == "claude-usage-native.json" }
        )
        XCTAssertTrue(seen.contains("claude-usage-native.json"))
    }

    // MARK: - Set up with no Node.js and no Python

    func testSetUpWithoutNodeOrPythonFillsClaudeInAppAndScoresCodexFromSessions() throws {
        let fm = FileManager.default
        let root = try tempDir("no-runtimes")
        let bundledBin = root.appendingPathComponent("bundled-bin")
        let templates = root.appendingPathComponent("templates")
        let support = root.appendingPathComponent("support")
        let launchd = root.appendingPathComponent("launchd")
        let state = root.appendingPathComponent("state")
        let sessions = root.appendingPathComponent("codex-sessions/2026/09/30")
        for dir in [bundledBin, templates, state, sessions] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let refresh = bundledBin.appendingPathComponent("codex-usage-refresh")
        try "#!/bin/sh\nexit 1\n".write(to: refresh, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: refresh.path)
        for label in BundledHelpers.coreLaunchdLabels {
            try "<plist><dict><key>Label</key><string>\(label)</string></dict></plist>"
                .write(to: templates.appendingPathComponent("\(label).plist"), atomically: true, encoding: .utf8)
        }
        // A Codex session event from a native-installer Codex (no Node.js).
        let stamp = ISO8601DateFormatter().string(from: Date())
        let resets = Int(Date().addingTimeInterval(3 * 86_400).timeIntervalSince1970)
        let event = """
        {"timestamp":"\(stamp)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":7.0,"window_minutes":300,"resets_at":\(resets)},"secondary":{"used_percent":31.0,"window_minutes":10080,"resets_at":\(resets)}}}}
        """
        try (event + "\n").write(to: sessions.appendingPathComponent("rollout-test.jsonl"), atomically: true, encoding: .utf8)

        var triggers: [ClaudeNativeTrigger] = []
        let now = Date()
        let recorder = Recorder()
        recorder.token = fakeToken
        recorder.responses = [okResponse(liveBody(session: 12, week: 9, fable: nil, now: now))]
        let nativeReader = makeReader(file: state.appendingPathComponent(UsagePaths.claudeNativeUsageFilename), clock: { now }, recorder: recorder)
        let paths = BackgroundRefreshService.Paths(
            supportDirectory: support,
            launchdDirectory: launchd,
            bundledBinDirectory: bundledBin,
            templateDirectory: templates,
            home: root,
            stateDirectory: state,
            appExecutable: root.appendingPathComponent("Applications/CodexUsageHUD.app/Contents/MacOS/CodexUsageHUD").path,
            invokeLaunchctl: false,
            nodeAvailable: false,
            pythonAvailable: false,
            codexSessionsRoot: root.appendingPathComponent("codex-sessions"),
            claudeNative: { trigger in
                triggers.append(trigger)
                // The live hook asks the coexistence rule first; mirror it
                // here against this test's own launchd directory.
                let installed = { (label: String) in fm.fileExists(atPath: launchd.appendingPathComponent("\(label).plist").path) }
                guard ClaudeNativeCoexistence.decide(
                    isolatedStateDir: false,
                    claudeConnected: true,
                    setUpDone: BundledHelpers.coreLaunchdLabels.contains(where: installed),
                    writerInstalled: installed(ClaudeNativeCoexistence.writerLabel),
                    sharedFileModifiedAt: nil,
                    now: now
                ) == .run else { return .skipped("stand down") }
                return nativeReader.run(trigger: trigger)
            }
        )
        // Without Node.js no writer file can appear, and Claude's in-app file
        // already exists, so Set up must not sit out its wait timeout.
        let outcome = BackgroundRefreshService.setUpAndRefresh(
            paths: paths,
            providers: ["claude", "codex", "gemini"],
            waitTimeout: 5,
            sleep: { _ in XCTFail("Set up waited for a file that cannot appear") }
        )

        XCTAssertEqual(triggers, [.setup])
        XCTAssertFalse(fm.fileExists(atPath: launchd.appendingPathComponent("com.codexusagehud.claude-writer.plist").path))
        XCTAssertTrue(outcome.report.text.contains("com.codexusagehud.claude-writer: skipped (needs Node.js)"), outcome.report.text)
        XCTAssertTrue(outcome.report.text.contains("claude-writer: kickstart skipped (not installed)"), outcome.report.text)
        XCTAssertTrue(outcome.report.text.contains("Claude in-app reader: ok"), outcome.report.text)
        XCTAssertTrue(outcome.hasData)
        XCTAssertEqual(outcome.lanes.first { $0.provider == "claude" }?.line, "Claude ✓ 9% of the week used · official")
        XCTAssertEqual(outcome.lanes.first { $0.provider == "codex" }?.line, "Codex ✓ 31% of the week used · high")
        XCTAssertEqual(outcome.lanes.first { $0.provider == "gemini" }?.line, "Gemini ✗ needs Node.js")
        XCTAssertFalse(outcome.lanes.map(\.line).joined().contains("Python"))
    }

    func testRuntimeNoteNamesOnlyTheNodeLanesThisMacHas() throws {
        let home = try tempDir("runtime-note")
        let fm = FileManager.default
        try fm.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: home.appendingPathComponent(".claude/.credentials.json"))
        try fm.createDirectory(at: home.appendingPathComponent(".codex/sessions"), withIntermediateDirectories: true)
        func note() -> String? {
            ToolDetection.detect(probe: .fileSystem(home: home, nodeAvailable: false, python3Available: false)).runtimeNote
        }
        XCTAssertNil(note(), "Claude and Codex are read in-app; nothing to install")

        let bin = home.appendingPathComponent(".local/bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: bin.appendingPathComponent("agy"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("agy").path)
        XCTAssertEqual(note(), "Gemini needs Node.js. \(RuntimeDependencies.nodeInstallHint).")

        let empty = try tempDir("runtime-note-empty")
        XCTAssertEqual(
            ToolDetection.detect(probe: .fileSystem(home: empty, nodeAvailable: false)).runtimeNote,
            "Gemini and Grok need Node.js. \(RuntimeDependencies.nodeInstallHint).",
            "with nothing found, Set up tries every lane"
        )
    }
}
