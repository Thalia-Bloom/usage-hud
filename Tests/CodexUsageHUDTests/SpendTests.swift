import AppKit
import XCTest
@testable import CodexUsageHUD

/// Token readers, pricing, plans, the value multiple and Activity grouping.
final class SpendTests: XCTestCase {
    // 2026-10-01 18:00:00 UTC
    let now = Date(timeIntervalSince1970: 1_791_223_200)

    private func iso(_ offset: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: now.addingTimeInterval(offset))
    }

    private func tempRoot() throws -> URL {
        let dir = TestTemporaryDirectory.root.appendingPathComponent("spend-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func write(_ lines: [String], to url: URL, modified: Date? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified ?? now.addingTimeInterval(-60)], ofItemAtPath: url.path)
    }

    private func roots(_ root: URL) -> TokenLogRoots {
        TokenLogRoots.resolve(env: ["CODEX_USAGE_HUD_TOKEN_LOGS": root.path], home: root, isolated: true)
    }

    // MARK: Fixture lines

    private func claudeLine(id: String, request: String = "req_1", at offset: TimeInterval, model: String = "claude-opus-5-5",
                            input: Int = 10, output: Int = 100, write5m: Int = 0, write1h: Int = 0, read: Int = 0,
                            cwd: String = "/Users/someone/Projects/alpha", session: String = "s-1", text: String = "hi") -> String {
        #"{"parentUuid":null,"isSidechain":false,"userType":"external","cwd":"\#(cwd)","sessionId":"\#(session)","version":"2.1.0","message":{"model":"\#(model)","id":"\#(id)","type":"message","role":"assistant","content":[{"type":"text","text":"\#(text)"}],"stop_reason":null,"usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(write5m + write1h),"cache_read_input_tokens":\#(read),"cache_creation":{"ephemeral_5m_input_tokens":\#(write5m),"ephemeral_1h_input_tokens":\#(write1h)},"output_tokens":\#(output),"service_tier":"standard"}},"requestId":"\#(request)","type":"assistant","uuid":"u-\#(id)","timestamp":"\#(iso(offset))"}"#
    }

    private func claudeUserLineWithTaskUsage(at offset: TimeInterval) -> String {
        // A Task tool result carries the subagent's usage; it must not count.
        #"{"cwd":"/Users/someone/Projects/alpha","sessionId":"s-1","message":{"role":"user","content":[{"type":"tool_result","content":"done"}]},"toolUseResult":{"usage":{"input_tokens":999999,"output_tokens":999999},"role":"assistant"},"type":"user","timestamp":"\#(iso(offset))"}"#
    }

    private func codexMeta(id: String, cwd: String = "/Users/someone/Projects/beta", forkedFrom: String? = nil) -> String {
        let fork = forkedFrom.map { #","forked_from_id":"\#($0)","parent_thread_id":"\#($0)""# } ?? ""
        return #"{"timestamp":"\#(iso(-3600))","type":"session_meta","payload":{"id":"\#(id)","timestamp":"\#(iso(-3600))","cwd":"\#(cwd)","originator":"codex_exec","cli_version":"0.158.0"\#(fork)}}"#
    }

    private func codexTurn(model: String) -> String {
        #"{"timestamp":"\#(iso(-3500))","type":"turn_context","payload":{"cwd":"/Users/someone/Projects/beta","model":"\#(model)","effort":"medium"}}"#
    }

    private func codexCount(at offset: TimeInterval, total: (Int, Int, Int, Int), last: (Int, Int, Int, Int), plan: String = "pro") -> String {
        func usage(_ u: (Int, Int, Int, Int)) -> String {
            #"{"input_tokens":\#(u.0),"cached_input_tokens":\#(u.1),"cache_write_input_tokens":0,"output_tokens":\#(u.2),"reasoning_output_tokens":\#(u.3),"total_tokens":\#(u.0 + u.2)}"#
        }
        return #"{"timestamp":"\#(iso(offset))","ordinal":1,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":\#(usage(total)),"last_token_usage":\#(usage(last)),"model_context_window":258400},"rate_limits":{"limit_id":"codex","primary":{"used_percent":12.0,"window_minutes":10080,"resets_at":1791500000},"plan_type":"\#(plan)"}}}"#
    }

    // MARK: Claude reader

    func testClaudeCountsEachMessageOnceKeepingTheLargestReading() throws {
        let root = try tempRoot()
        try write([
            claudeLine(id: "msg_A", at: -600, input: 5, output: 8, write1h: 1000, read: 20_000),
            claudeLine(id: "msg_A", at: -600, input: 5, output: 240, write1h: 1000, read: 20_000),
            claudeUserLineWithTaskUsage(at: -500),
            claudeLine(id: "msg_B", request: "req_2", at: -300, input: 7, output: 50, write5m: 400, read: 1000),
            claudeLine(id: "msg_C", request: "req_3", at: -200, model: "<synthetic>", input: 0, output: 0),
        ], to: root.appendingPathComponent("claude/projects/-Users-someone-Projects-alpha/s-1.jsonl"))

        let scan = TokenUsageIndex().scan(roots: roots(root), now: now)
        let files = scan.files.filter { $0.tool == .claude }
        XCTAssertEqual(files.count, 1)
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(file.project, "alpha")
        XCTAssertEqual(file.sessionID, "s-1")
        XCTAssertEqual(file.events.count, 2)
        XCTAssertEqual(file.events[0].counts, TokenCounts(input: 5, cacheWrite5m: 0, cacheWrite1h: 1000, cacheRead: 20_000, output: 240))
        XCTAssertEqual(file.events[1].counts, TokenCounts(input: 7, cacheWrite5m: 400, cacheWrite1h: 0, cacheRead: 1000, output: 50))
    }

    func testClaudeLongLineIsReadByKeyLikeAShortOne() throws {
        let big = String(repeating: "x", count: ClaudeTranscriptParser.fullDecodeLimit + 500)
        let short = claudeLine(id: "msg_L", at: -60, input: 3, output: 77, write5m: 10, write1h: 20, read: 30)
        let long = claudeLine(id: "msg_L", at: -60, input: 3, output: 77, write5m: 10, write1h: 20, read: 30, text: big)
        let a = short.utf8CString.withUnsafeBytes { ClaudeTranscriptParser.decoded(UnsafeRawBufferPointer(rebasing: $0.dropLast())) }
        let b = long.utf8CString.withUnsafeBytes { ClaudeTranscriptParser.keyed(UnsafeRawBufferPointer(rebasing: $0.dropLast())) }
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
        XCTAssertEqual(b?.key, "msg_L:req_1")
    }

    func testResumedClaudeSessionCopyIsCountedOnce() throws {
        let root = try tempRoot()
        let dir = root.appendingPathComponent("claude/projects/-Users-someone-Projects-alpha")
        try write([claudeLine(id: "msg_A", at: -900, output: 100)], to: dir.appendingPathComponent("s-1.jsonl"))
        try write([claudeLine(id: "msg_A", at: -900, output: 100, session: "s-2"),
                   claudeLine(id: "msg_N", request: "req_9", at: -100, output: 100, session: "s-2")],
                  to: dir.appendingPathComponent("s-2.jsonl"))
        let scan = TokenUsageIndex().scan(roots: roots(root), now: now)
        let events = SpendEvents.unique(scan.files)
        XCTAssertEqual(events.count, 2, "msg_A appears in both files and counts once")
    }

    // MARK: Codex reader

    func testCodexCountsTheChangeInTheRunningTotalNotRepeatedEvents() throws {
        let root = try tempRoot()
        try write([
            codexMeta(id: "t-1"),
            codexTurn(model: "gpt-6-sol"),
            codexCount(at: -1800, total: (1000, 200, 50, 10), last: (1000, 200, 50, 10)),
            // The same total written again (a rate-limit update): adds nothing.
            codexCount(at: -1790, total: (1000, 200, 50, 10), last: (1000, 200, 50, 10)),
            codexCount(at: -600, total: (3000, 1200, 80, 10), last: (2000, 1000, 30, 0)),
        ], to: root.appendingPathComponent("codex/sessions/2026/10/01/rollout-2026-10-01T10-00-00-t-1.jsonl"))

        let scan = TokenUsageIndex().scan(roots: roots(root), now: now)
        let file = try XCTUnwrap(scan.files.first { $0.tool == .codex })
        XCTAssertEqual(file.sessionID, "t-1")
        XCTAssertEqual(file.project, "beta")
        XCTAssertEqual(file.planType, "pro")
        let sum = file.events.reduce(TokenCounts()) { $0 + $1.counts }
        // input 3000 of which 1200 cached; output 80 of which 10 reasoning.
        XCTAssertEqual(sum, TokenCounts(input: 1800, cacheRead: 1200, output: 80, reasoning: 10))
        XCTAssertEqual(Set(file.events.map(\.model)), ["gpt-6-sol"])
    }

    func testCodexTotalGoingBackwardsCountsTheLastRequest() {
        var parser = CodexRolloutParser(fallbackSessionID: "x")
        for line in [
            codexTurn(model: "gpt-6-sol"),
            codexCount(at: -900, total: (5000, 0, 100, 0), last: (5000, 0, 100, 0)),
            codexCount(at: -300, total: (700, 0, 20, 0), last: (700, 0, 20, 0)),
        ] {
            line.utf8CString.withUnsafeBytes { parser.consume(UnsafeRawBufferPointer(rebasing: $0.dropLast())) }
        }
        let sum = parser.file.events.reduce(TokenCounts()) { $0 + $1.counts }
        XCTAssertEqual(sum.input, 5700)
        XCTAssertEqual(sum.output, 120)
    }

    func testCodexForkIsAHelperOfItsParentSession() throws {
        let root = try tempRoot()
        let day = root.appendingPathComponent("codex/sessions/2026/10/01")
        try write([codexMeta(id: "parent"), codexTurn(model: "gpt-6-sol"),
                   codexCount(at: -1200, total: (1000, 0, 100, 0), last: (1000, 0, 100, 0))],
                  to: day.appendingPathComponent("rollout-a-parent.jsonl"))
        // A forked helper copies its parent's meta after its own.
        try write([codexMeta(id: "child", forkedFrom: "parent"), codexMeta(id: "parent"), codexTurn(model: "gpt-6-luna"),
                   codexCount(at: -600, total: (500, 0, 50, 0), last: (500, 0, 50, 0))],
                  to: day.appendingPathComponent("rollout-b-child.jsonl"))
        let scan = TokenUsageIndex().scan(roots: roots(root), now: now)
        let child = try XCTUnwrap(scan.files.first { $0.sessionID == "child" })
        XCTAssertEqual(child.parentSessionID, "parent")

        let activity = ActivitySummary.make(scan: scan, now: now)
        XCTAssertEqual(activity.sessions.count, 1)
        XCTAssertEqual(activity.sessions.first?.helpers, 1)
        XCTAssertEqual(activity.sessions.first?.tokens, 1650)
    }

    // MARK: Gemini reader

    func testGeminiKeepsTheLastWriteOfAMessage() throws {
        let root = try tempRoot()
        let chats = root.appendingPathComponent("gemini/tmp/gamma/chats")
        func message(_ input: Int, _ cached: Int, _ output: Int, _ thoughts: Int) -> String {
            #"{"id":"m-1","timestamp":"\#(iso(-400))","type":"gemini","content":"…","tokens":{"input":\#(input),"output":\#(output),"cached":\#(cached),"thoughts":\#(thoughts),"tool":0,"total":\#(input + output + thoughts)},"model":"gemini-3.1-pro-preview"}"#
        }
        try write([
            #"{"sessionId":"g-1","projectHash":"abc","startTime":"\#(iso(-500))","kind":"main"}"#,
            message(1000, 0, 10, 5),
            message(1000, 400, 30, 20),
        ], to: chats.appendingPathComponent("session-2026-10-01T10-00-g1.jsonl"))
        let scan = TokenUsageIndex().scan(roots: roots(root), now: now)
        let file = try XCTUnwrap(scan.files.first { $0.tool == .gemini })
        XCTAssertEqual(file.sessionID, "g-1")
        XCTAssertEqual(file.project, "gamma")
        XCTAssertEqual(file.events.count, 1)
        XCTAssertEqual(file.events[0].counts, TokenCounts(input: 600, cacheRead: 400, output: 50, reasoning: 20))
    }

    // MARK: Index

    func testGrowingFileIsReadFromWhereTheLastScanStopped() throws {
        let root = try tempRoot()
        let url = root.appendingPathComponent("claude/projects/p/s-1.jsonl")
        try write([claudeLine(id: "msg_1", at: -900, output: 10)], to: url)
        let index = TokenUsageIndex()
        let first = index.scan(roots: roots(root), now: now)
        XCTAssertEqual(first.filesParsed, 1)
        XCTAssertEqual(first.files.first?.events.count, 1)

        let unchanged = index.scan(roots: roots(root), now: now)
        XCTAssertEqual(unchanged.filesParsed, 0, "an unchanged file is not read again")

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((claudeLine(id: "msg_2", request: "req_2", at: -100, output: 20) + "\n").utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30)], ofItemAtPath: url.path)

        let grown = index.scan(roots: roots(root), now: now)
        XCTAssertEqual(grown.filesParsed, 1)
        XCTAssertEqual(grown.files.first?.events.map(\.counts.output), [10, 20])
    }

    func testSettledFileThatGrowsAgainIsReadWholeOnce() throws {
        let root = try tempRoot()
        let url = root.appendingPathComponent("claude/projects/p/s-1.jsonl")
        try write([claudeLine(id: "msg_1", at: -8 * 3600, output: 10)], to: url, modified: now.addingTimeInterval(-7 * 3600))
        let index = TokenUsageIndex()
        XCTAssertEqual(index.scan(roots: roots(root), now: now).files.first?.events.count, 1)
        try write([claudeLine(id: "msg_1", at: -8 * 3600, output: 10),
                   claudeLine(id: "msg_2", request: "req_2", at: -60, output: 20)], to: url, modified: now.addingTimeInterval(-30))
        let again = index.scan(roots: roots(root), now: now)
        XCTAssertEqual(again.files.first?.events.map(\.counts.output), [10, 20])
    }

    func testLogsOlderThanTheWindowAreNotRead() throws {
        let root = try tempRoot()
        try write([claudeLine(id: "msg_old", at: -40 * 86_400, output: 10)],
                  to: root.appendingPathComponent("claude/projects/p/old.jsonl"),
                  modified: now.addingTimeInterval(-40 * 86_400))
        let scan = TokenUsageIndex().scan(roots: roots(root), now: now)
        XCTAssertTrue(scan.files.isEmpty)
        XCTAssertTrue(scan.toolsWithLogs.contains(.claude))
    }

    func testIsolatedStateReadsNoLiveLogs() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(TokenLogRoots.resolve(env: [:], home: home, isolated: true), .none)
        XCTAssertEqual(TokenLogRoots.resolve(env: ["CODEX_USAGE_HUD_TOKEN_LOGS": "off"], home: home, isolated: false), .none)
        let live = TokenLogRoots.resolve(env: [:], home: home, isolated: false)
        XCTAssertEqual(live.claudeProjects.first?.path, "/Users/someone/.claude/projects")
        XCTAssertEqual(live.codexSessions.first?.path, "/Users/someone/.codex/sessions")
        XCTAssertEqual(TokenLogRoots.resolve(env: ["CODEX_USAGE_HUD_TOKEN_LOGS": "live"], home: home, isolated: true), live)
    }

    // MARK: Pricing

    func testOpusPricingSeparatesCacheWriteDurations() {
        let counts = TokenCounts(input: 1_000_000, cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        let cost = APIPricing.cost(counts, model: "claude-opus-5-5")
        XCTAssertEqual(cost.usd, 4 + 5 + 8 + 0.20 + 20, accuracy: 1e-9)
        XCTAssertFalse(cost.estimated)
        XCTAssertEqual(APIPricing.cost(counts, model: "claude-opus-5-5[1m]").usd, cost.usd, accuracy: 1e-9)
        XCTAssertEqual(APIPricing.quote(model: "claude-haiku-4-5-20251001").pricedAs, "claude-haiku-4-5")
    }

    func testLongPromptsUseTheLongContextTier() {
        XCTAssertTrue(APIPricing.isLongContext(model: "gpt-6-sol", promptTokens: 300_000))
        XCTAssertFalse(APIPricing.isLongContext(model: "gpt-6-sol", promptTokens: 200_000))
        XCTAssertFalse(APIPricing.isLongContext(model: "claude-opus-5-5", promptTokens: 900_000))
        let counts = TokenCounts(input: 1_000_000, output: 1_000_000)
        XCTAssertEqual(APIPricing.cost(counts, model: "gpt-6-sol", longContext: true).usd, 4 + 15, accuracy: 1e-9)
        XCTAssertEqual(APIPricing.cost(counts, model: "gpt-6-sol").usd, 2 + 10, accuracy: 1e-9)
    }

    func testUnknownModelsUseAFamilyDefaultAndSaySo() {
        let opus = APIPricing.quote(model: "claude-opus-9")
        XCTAssertEqual(opus.pricedAs, "claude-opus-5-5")
        XCTAssertTrue(opus.estimated)
        XCTAssertTrue(APIPricing.quote(model: "sonnet").estimated)
        let review = APIPricing.quote(model: "codex-auto-review")
        XCTAssertEqual(review.pricedAs, "gpt-5.6-luna")
        XCTAssertTrue(review.estimated)
        let daybreak = APIPricing.quote(model: "gpt-daybreak-blue-latest")
        XCTAssertEqual(daybreak.pricedAs, "gpt-5.6-sol")
        XCTAssertFalse(daybreak.estimated)
        let local = APIPricing.quote(model: "qwen3:4b")
        XCTAssertTrue(local.local)
        XCTAssertEqual(local.rate.cost(TokenCounts(input: 1_000_000, output: 1_000_000)), 0)
        XCTAssertTrue(APIPricing.quote(model: "mystery-model", tool: .gemini).estimated)
    }

    func testEveryPriceRowNamesAnOfficialSourceAndDate() {
        for row in APIPricing.table {
            XCTAssertTrue(row.source.hasPrefix("https://"), row.ids.joined())
            XCTAssertEqual(row.checked, "2026-10-01")
        }
        for plan in PlanCatalog.plans {
            XCTAssertTrue(plan.source.hasPrefix("https://"), plan.id)
        }
    }

    // MARK: Plans

    func testClaudePlanDetection() {
        XCTAssertEqual(PlanDetection.claude(subscriptionType: nil, organizationType: "claude_max", rateLimitTier: "default_claude_max_20x")?.planID, "claude-max-20x")
        XCTAssertEqual(PlanDetection.claude(subscriptionType: "max", organizationType: nil, rateLimitTier: "default_claude_max_5x")?.monthlyUSD, 100)
        let bareMax = PlanDetection.claude(subscriptionType: "max", organizationType: nil, rateLimitTier: nil)
        XCTAssertEqual(bareMax?.name, "Max")
        XCTAssertNil(bareMax?.monthlyUSD, "Max without its tier names the plan but guesses no price")
        XCTAssertEqual(PlanDetection.claude(subscriptionType: "pro", organizationType: nil, rateLimitTier: nil)?.monthlyUSD, 20)
        XCTAssertNil(PlanDetection.claude(subscriptionType: nil, organizationType: nil, rateLimitTier: nil))
    }

    func testCodexPlanDetection() {
        XCTAssertEqual(PlanDetection.codex(planType: "prolite")?.monthlyUSD, 100)
        XCTAssertEqual(PlanDetection.codex(planType: "pro")?.monthlyUSD, 200)
        XCTAssertEqual(PlanDetection.codex(planType: "promax")?.monthlyUSD, 500)
        XCTAssertEqual(PlanDetection.codex(planType: "plus")?.monthlyUSD, 20)
        XCTAssertNil(PlanDetection.codex(planType: "weird"))
    }

    func testClaudeConfigReadsOnlyThePlanFields() throws {
        let root = try tempRoot()
        let url = root.appendingPathComponent("claude.json")
        try Data(#"{"oauthAccount":{"emailAddress":"a@b.c","organizationType":"claude_max","organizationRateLimitTier":"default_claude_max_20x"},"projects":{}}"#.utf8).write(to: url)
        let fields = try XCTUnwrap(PlanDetection.claudeAccountFields(configURL: url))
        XCTAssertEqual(fields.organizationType, "claude_max")
        XCTAssertEqual(fields.rateLimitTier, "default_claude_max_20x")
    }

    func testKeychainPlanFieldsNeverIncludeTheToken() {
        let value = Data(#"{"claudeAiOauth":{"accessToken":"secret-token","refreshToken":"r","subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}"#.utf8)
        let fields = ClaudeNativeCredential.planFields(fromKeychainValue: value)
        XCTAssertEqual(fields, ["subscriptionType": "max", "rateLimitTier": "default_claude_max_20x"])
    }

    func testPlanChoiceRoundTripsAndResolves() {
        for choice in [PlanChoice.auto, .none, .custom(42.5), .plan("claude-pro")] {
            XCTAssertEqual(PlanChoice(stored: choice.stored), choice)
        }
        XCTAssertEqual(PlanChoice(stored: "nonsense"), .auto)
        let detected = PlanDetection.codex(planType: "pro")
        XCTAssertEqual(ResolvedPlan.resolve(choice: .auto, detected: detected).source, .detected)
        XCTAssertEqual(ResolvedPlan.resolve(choice: .auto, detected: nil), .unset)
        let custom = ResolvedPlan.resolve(choice: .custom(50), detected: detected)
        XCTAssertEqual(custom.source, .user)
        XCTAssertEqual(custom.monthlyUSD, 50)
        XCTAssertEqual(ResolvedPlan.resolve(choice: .plan("supergrok"), detected: nil).monthlyUSD, 30)
    }

    // MARK: Value multiple

    private func scanWith(_ files: [TokenLogFile], tools: Set<AgentTool> = [.claude, .codex, .gemini]) -> TokenScan {
        TokenScan(files: files, scannedAt: now, toolsWithLogs: tools, roots: .none, duration: 0, filesParsed: files.count)
    }

    private func event(_ hoursAgo: Double, model: String = "claude-sonnet-5", output: Int) -> TokenEvent {
        TokenEvent(at: now.addingTimeInterval(-hoursAgo * 3600), model: model, counts: TokenCounts(output: output))
    }

    func testValueMultipleComparesAPIValueWithWhatThePlanCosts() {
        // Sonnet 5 output: $10 per million. $100 today, $300 three days ago, $600 twenty days ago.
        var file = TokenLogFile(tool: .claude, sessionID: "s", project: "alpha")
        file.events = [event(1, output: 10_000_000), event(72, output: 30_000_000), event(480, output: 60_000_000)]
        let plans = ["claude": ResolvedPlan.resolve(choice: .plan("claude-max-20x"), detected: nil)]
        let summary = SpendSummary.make(scan: scanWith([file]), plans: plans, now: now, calendar: utc)
        let claude = try! XCTUnwrap(summary.provider("claude"))
        XCTAssertEqual(claude.apiValue?.today ?? 0, 100, accuracy: 1e-6)
        XCTAssertEqual(claude.apiValue?.week ?? 0, 400, accuracy: 1e-6)
        XCTAssertEqual(claude.apiValue?.month ?? 0, 1000, accuracy: 1e-6)
        XCTAssertEqual(claude.plan.source, "user")
        XCTAssertEqual(claude.valueMultiple ?? 0, 1000 / (200 * 30 / SpendPeriods.daysPerMonth), accuracy: 1e-6)
        XCTAssertEqual(summary.total.valueMultipleWeek ?? 0, 400 / (200 * 7 / SpendPeriods.daysPerMonth), accuracy: 1e-6)
        XCTAssertFalse(summary.billed)
        XCTAssertEqual(summary.provider("grok")?.apiValue, nil, "Grok's logs are not read: no API value, not $0")

        let line = try! XCTUnwrap(SpendDisplay.valueLine(summary, visibleProviders: ["claude", "codex"]))
        XCTAssertEqual(line.value, "$400")
        XCTAssertEqual(line.paid, "you pay \(SpendDisplay.money(200 * 7 / SpendPeriods.daysPerMonth)) of $200/mo")
        XCTAssertEqual(line.multiple, "8.7×")
        XCTAssertFalse(line.showSetPlan)
    }

    func testNoPlanShowsAPIValueAndASetPlanLink() {
        var file = TokenLogFile(tool: .codex, sessionID: "t", project: "beta")
        file.events = [event(2, model: "gpt-6-sol", output: 1_000_000)]
        let summary = SpendSummary.make(scan: scanWith([file]), plans: [:], now: now, calendar: utc)
        XCTAssertNil(summary.provider("codex")?.valueMultiple)
        XCTAssertEqual(summary.total.lanesWithoutPlan, ["codex"])
        let line = try! XCTUnwrap(SpendDisplay.valueLine(summary, visibleProviders: ["codex"]))
        XCTAssertEqual(line.value, "$10")
        XCTAssertNil(line.paid)
        XCTAssertTrue(line.showSetPlan)
        XCTAssertTrue(SpendDisplay.valueLine(nil, visibleProviders: ["codex"])?.reading == true)
        XCTAssertNil(SpendDisplay.valueLine(summary, visibleProviders: ["local"]))
    }

    // MARK: Activity

    func testActivityGroupsByToolNewestFirstWithBurnRate() {
        var a = TokenLogFile(tool: .claude, sessionID: "a", project: "alpha")
        a.events = [event(0.25, output: 3_000_000), event(3, output: 1_000_000)]
        a.fileKey = 1
        var b = TokenLogFile(tool: .codex, sessionID: "b", project: "beta")
        b.events = [event(0.1, model: "gpt-6-luna", output: 1_000_000)]
        b.fileKey = 2
        var old = TokenLogFile(tool: .claude, sessionID: "old", project: "gamma")
        old.events = [event(40, output: 1_000_000)]
        old.fileKey = 3

        let activity = ActivitySummary.make(scan: scanWith([a, b, old]), now: now, calendar: utc)
        XCTAssertEqual(activity.sessions.map(\.project), ["beta", "alpha"], "newest first; yesterday's session left out")
        XCTAssertEqual(activity.groups.map(\.tool), ["claude", "codex"])
        let alpha = activity.sessions[1]
        XCTAssertEqual(alpha.tokens, 4_000_000)
        XCTAssertEqual(alpha.apiValueUSD, 40, accuracy: 1e-9)
        XCTAssertEqual(alpha.usdPerHour, 30, accuracy: 1e-9, "only the last hour counts toward the burn rate")
        XCTAssertEqual(alpha.tokensPerHour, 3_000_000)
        XCTAssertEqual(activity.topBurner?.project, "alpha")
        XCTAssertEqual(activity.status, "ready")
    }

    func testActivityEmptyStateKnowsWhetherLogsExist() {
        XCTAssertEqual(ActivitySummary.make(scan: scanWith([], tools: []), now: now).status, "no_logs")
        XCTAssertEqual(ActivitySummary.make(scan: scanWith([]), now: now).status, "ready")
        XCTAssertTrue(ActivitySummary.make(scan: nil, now: now).sessions.isEmpty)
    }

    func testSummariesCarryNoPaths() throws {
        let root = try tempRoot()
        try write([claudeLine(id: "msg_1", at: -60, output: 10, cwd: "/Users/someone/Projects/secret-client/app")],
                  to: root.appendingPathComponent("claude/projects/-Users-someone-Projects-secret-client-app/s-1.jsonl"))
        let scan = TokenUsageIndex().scan(roots: roots(root), now: now)
        let spend = SpendSummary.make(scan: scan, plans: [:], now: now)
        let activity = ActivitySummary.make(scan: scan, now: now)
        let json = String(decoding: try SpendJSON.encoder.encode(spend), as: UTF8.self)
            + String(decoding: try SpendJSON.encoder.encode(activity), as: UTF8.self)
        XCTAssertFalse(json.contains("/Users"))
        XCTAssertFalse(json.contains("secret-client"))
        XCTAssertTrue(json.contains("\"project\" : \"app\""))
    }

    func testSavedSummaryAnswersOnlyWhileFresh() throws {
        let dir = try tempRoot()
        var file = TokenLogFile(tool: .claude, sessionID: "s", project: "alpha")
        file.events = [event(1, output: 1_000_000)]
        let scan = scanWith([file])
        let spend = SpendSummary.make(scan: scan, plans: [:], now: now, calendar: utc)
        SpendSnapshotFile.writeIfNewer(spend: spend, scan: scan, stateDirectory: dir)

        let saved = try XCTUnwrap(SpendSnapshotFile.read(now: now.addingTimeInterval(30), stateDirectory: dir, env: [:]))
        XCTAssertEqual(saved.spend, spend)
        XCTAssertEqual(saved.activity.sessions.map(\.project), ["alpha"])
        XCTAssertNil(SpendSnapshotFile.read(now: now.addingTimeInterval(600), stateDirectory: dir, env: [:]), "stale")
        XCTAssertNil(SpendSnapshotFile.read(now: now, stateDirectory: dir, env: ["CODEX_USAGE_HUD_TOKEN_LOGS": dir.path]),
                     "a fixture run never gets the app's live numbers")
        let mode = try FileManager.default.attributesOfItem(atPath: SpendSnapshotFile.url(stateDirectory: dir).path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    // MARK: Helpers

    func testProjectNames() {
        let home = "/Users/someone"
        XCTAssertEqual(ProjectName.from(cwd: "/Users/someone/Projects/alpha", homePath: home), "alpha")
        XCTAssertEqual(ProjectName.from(cwd: "/Users/someone/Projects/alpha/", homePath: home), "alpha")
        XCTAssertEqual(ProjectName.from(cwd: "/Users/someone/Projects/alpha/.claude/worktrees/agent-1", homePath: home), "alpha")
        XCTAssertEqual(ProjectName.from(cwd: "/Users/someone/.codex/worktrees/ab12/beta", homePath: home), "beta")
        XCTAssertEqual(ProjectName.from(cwd: "/Users/someone", homePath: home), ProjectName.home)
        XCTAssertEqual(ProjectName.from(cwd: "/private/tmp/claude-501/x", homePath: home), ProjectName.temporary)
        XCTAssertEqual(ProjectName.from(cwd: "/", homePath: home), ProjectName.root)
        XCTAssertEqual(ProjectName.from(cwd: nil, homePath: home), ProjectName.unknown)
    }

    func testFastTimestamps() {
        XCTAssertEqual(FastISO8601.parse("2026-09-29T22:18:48.560Z")?.timeIntervalSince1970 ?? 0, 1_790_720_328.56, accuracy: 0.001)
        XCTAssertEqual(FastISO8601.parse("2026-09-29T22:18:48Z")?.timeIntervalSince1970, 1_790_720_328)
        XCTAssertEqual(FastISO8601.parse("2026-09-29T15:18:48-07:00")?.timeIntervalSince1970, 1_790_720_328)
        XCTAssertNil(FastISO8601.parse("2026-09-29T22:18:48"))
        XCTAssertNil(FastISO8601.parse("yesterday"))
    }

    func testDisplayFormats() {
        XCTAssertEqual(SpendDisplay.money(4.1), "$4.10")
        XCTAssertEqual(SpendDisplay.money(412.4), "$412")
        XCTAssertEqual(SpendDisplay.money(3845.2), "$3,845")
        XCTAssertEqual(SpendDisplay.multiple(9.04), "9.0×")
        XCTAssertEqual(SpendDisplay.multiple(41.8), "42×")
        XCTAssertEqual(SpendDisplay.tokens(475_026_371), "475M")
        XCTAssertEqual(SpendDisplay.tokens(7_094_946_356), "7.1B")
        XCTAssertEqual(SpendDisplay.perHour(4.1), "$4.10/h")
    }

    func testActivityWindowKeys() {
        XCTAssertEqual(ActivityWindowController.keyAction(characters: "w", modifiers: .command, keyCode: 13), .close)
        XCTAssertEqual(ActivityWindowController.keyAction(characters: "r", modifiers: .command, keyCode: 15), .refresh)
        XCTAssertEqual(ActivityWindowController.keyAction(characters: "\u{1B}", modifiers: [], keyCode: 53), .close)
        XCTAssertNil(ActivityWindowController.keyAction(characters: "w", modifiers: [], keyCode: 13))
        XCTAssertNil(ActivityWindowController.keyAction(characters: "w", modifiers: [.command, .shift], keyCode: 13))
        XCTAssertNil(ActivityWindowController.keyAction(characters: "q", modifiers: .command, keyCode: 12), "Cmd-Q stays with the app")
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}
