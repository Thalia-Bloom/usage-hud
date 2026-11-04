import Foundation

// Line parsers for the three tools' session logs. Each one is a value type
// that can stop at the end of a file and carry on when the file grows, so a
// running session costs only its new lines on the next scan.

// MARK: - Claude Code

/// Reads one Claude Code transcript (`~/.claude/projects/<project>/<session>.jsonl`,
/// including `<session>/subagents/*.jsonl`).
///
/// Only assistant lines carry `message.usage` (input, output, cache writes
/// with their 5-minute / 1-hour split, cache reads). Claude Code writes one
/// line per content block, so a message appears several times with the
/// same message id and request id; it counts once, keeping the largest
/// reading of each field (early lines can carry a partial output count).
struct ClaudeTranscriptParser: Sendable {
    private(set) var file: TokenLogFile
    private var index: [String: Int] = [:]
    private var projectSet = false

    /// Lines longer than this are read by key instead of decoded whole:
    /// an assistant line that wrote a big file can run to megabytes.
    static let fullDecodeLimit = 16 * 1024

    init(fallbackSessionID: String) {
        file = TokenLogFile(tool: .claude, sessionID: fallbackSessionID)
    }

    /// `message.role` sits after a handful of short top-level keys (cwd,
    /// sessionId, version, branch), well inside this many bytes.
    static let roleWindow = 8 * 1024

    mutating func consume(_ line: UnsafeRawBufferPointer) {
        guard ByteSearch.contains("\"role\":\"assistant\"", inFirst: Self.roleWindow, of: line),
              let entry = Self.entry(from: line)
        else { return }
        if !projectSet, let cwd = entry.cwd {
            file.project = ProjectName.from(cwd: cwd)
            projectSet = true
        }
        if let sessionID = entry.sessionID, !sessionID.isEmpty, file.events.isEmpty {
            file.sessionID = sessionID
        }
        guard entry.model != "<synthetic>", !entry.counts.isZero else { return }
        let event = TokenEvent(at: entry.at, model: entry.model, counts: entry.counts, key: entry.key, fast: entry.fast)
        if let key = entry.key, let existing = index[key] {
            file.events[existing].counts = file.events[existing].counts.fieldMax(entry.counts)
            return
        }
        if let key = entry.key { index[key] = file.events.count }
        file.events.append(event)
    }

    struct Entry: Equatable {
        var at: Date
        var model: String
        var counts: TokenCounts
        var key: String?
        var sessionID: String?
        var cwd: String?
        var fast = false
    }

    static func entry(from line: UnsafeRawBufferPointer) -> Entry? {
        if line.count <= fullDecodeLimit {
            return decoded(line)
        }
        return keyed(line) ?? decoded(line)
    }

    /// Whole-line decode: the reference reading.
    static func decoded(_ line: UnsafeRawBufferPointer) -> Entry? {
        guard let object = ByteSearch.jsonObject(in: line),
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let stamp = object["timestamp"] as? String,
              let at = FastISO8601.parse(stamp)
        else { return nil }
        let messageID = message["id"] as? String
        let requestID = object["requestId"] as? String
        return Entry(
            at: at,
            model: (message["model"] as? String) ?? "unknown",
            counts: counts(usage),
            key: dedupeKey(messageID: messageID, requestID: requestID),
            sessionID: object["sessionId"] as? String,
            cwd: object["cwd"] as? String,
            fast: (usage["speed"] as? String)?.lowercased() == "fast"
        )
    }

    /// Reads the handful of keys a long line needs without decoding its
    /// content. Top-level keys (cwd, sessionId) come before `message`;
    /// `message.role` and `message.model` come before its content and
    /// `message.usage` after it, so the first role/model and the last usage
    /// are the message's own. Anything unexpected falls back to `decoded`.
    static func keyed(_ line: UnsafeRawBufferPointer) -> Entry? {
        guard ByteSearch.stringValue(after: "\"role\":\"", in: line) == "assistant",
              let usageKey = ByteSearch.findLast("\"usage\":{", in: line),
              let range = ByteSearch.objectRange(openingAt: usageKey + 8, in: line),
              let usage = ByteSearch.jsonObject(in: line, range: range),
              usage["output_tokens"] != nil || usage["input_tokens"] != nil,
              let stamp = ByteSearch.stringValue(after: "\"timestamp\":\"", in: line, last: true),
              let at = FastISO8601.parse(stamp)
        else { return nil }
        let messageID = ByteSearch.stringValue(after: "\"id\":\"msg", in: line).map { "msg" + $0 }
        let requestID = ByteSearch.stringValue(after: "\"requestId\":\"", in: line, last: true)
        return Entry(
            at: at,
            model: ByteSearch.stringValue(after: "\"model\":\"", in: line) ?? "unknown",
            counts: counts(usage),
            key: dedupeKey(messageID: messageID, requestID: requestID),
            sessionID: ByteSearch.stringValue(after: "\"sessionId\":\"", in: line),
            cwd: ByteSearch.stringValue(after: "\"cwd\":\"", in: line),
            fast: (usage["speed"] as? String)?.lowercased() == "fast"
        )
    }

    static func dedupeKey(messageID: String?, requestID: String?) -> String? {
        guard let messageID, !messageID.isEmpty else { return nil }
        return "\(messageID):\(requestID ?? "")"
    }

    /// Anthropic usage: `input_tokens` is already uncached input; cache
    /// writes and reads are reported beside it.
    static func counts(_ usage: [String: Any]) -> TokenCounts {
        let writes = usage.int("cache_creation_input_tokens")
        var write1h = 0
        if let split = usage["cache_creation"] as? [String: Any] {
            write1h = min(writes, split.int("ephemeral_1h_input_tokens"))
        }
        let details = usage["output_tokens_details"] as? [String: Any]
        return TokenCounts(
            input: usage.int("input_tokens"),
            cacheWrite5m: max(0, writes - write1h),
            cacheWrite1h: write1h,
            cacheRead: usage.int("cache_read_input_tokens"),
            output: usage.int("output_tokens"),
            reasoning: details?.int("thinking_tokens") ?? 0
        )
    }
}

// MARK: - Codex

/// Reads one Codex rollout (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`).
///
/// `token_count` events carry the thread's running total
/// (`total_token_usage`) and the last request (`last_token_usage`). The
/// same total is often written twice (a rate-limit update repeats it), so
/// summing `last_token_usage` over-counts; the reader counts the change in
/// the running total instead, and falls back to the last request only when
/// the total goes backwards (a reset). OpenAI semantics: `input_tokens`
/// includes cached and cache-write tokens, `output_tokens` includes
/// reasoning tokens.
struct CodexRolloutParser: Sendable {
    private(set) var file: TokenLogFile
    private var previousTotal: RawUsage?
    private var model: String?
    private var metaSeen = false

    struct RawUsage: Equatable, Sendable {
        var input = 0, cached = 0, cacheWrite = 0, output = 0, reasoning = 0

        init(_ dict: [String: Any]) {
            input = dict.int("input_tokens")
            cached = dict.int("cached_input_tokens")
            cacheWrite = dict.int("cache_write_input_tokens")
            output = dict.int("output_tokens")
            reasoning = dict.int("reasoning_output_tokens")
        }

        init(input: Int, cached: Int, cacheWrite: Int, output: Int, reasoning: Int) {
            self.input = input; self.cached = cached; self.cacheWrite = cacheWrite
            self.output = output; self.reasoning = reasoning
        }

        static func - (lhs: RawUsage, rhs: RawUsage) -> RawUsage {
            RawUsage(input: lhs.input - rhs.input, cached: lhs.cached - rhs.cached,
                     cacheWrite: lhs.cacheWrite - rhs.cacheWrite, output: lhs.output - rhs.output,
                     reasoning: lhs.reasoning - rhs.reasoning)
        }

        var anyNegative: Bool { input < 0 || cached < 0 || cacheWrite < 0 || output < 0 || reasoning < 0 }
        var isZero: Bool { input == 0 && cached == 0 && cacheWrite == 0 && output == 0 && reasoning == 0 }

        var counts: TokenCounts {
            let cacheRead = max(0, cached)
            let writes = max(0, cacheWrite)
            return TokenCounts(
                input: max(0, input - cacheRead - writes),
                cacheWrite5m: writes,
                cacheRead: cacheRead,
                output: max(0, output),
                reasoning: max(0, reasoning)
            )
        }
    }

    init(fallbackSessionID: String) {
        file = TokenLogFile(tool: .codex, sessionID: fallbackSessionID)
    }

    /// Every rollout line opens with its timestamp, ordinal and type
    /// (`{"timestamp":…,"type":"event_msg","payload":{"type":"token_count"`),
    /// so the type is found without scanning a long line.
    static let typeWindow = 320

    mutating func consume(_ line: UnsafeRawBufferPointer) {
        if ByteSearch.contains("\"token_count\"", inFirst: Self.typeWindow, of: line) {
            consumeTokenCount(line)
        } else if ByteSearch.contains("\"turn_context\"", inFirst: Self.typeWindow, of: line) {
            guard let object = ByteSearch.jsonObject(in: line),
                  object["type"] as? String == "turn_context",
                  let payload = object["payload"] as? [String: Any] else { return }
            if let m = payload["model"] as? String, !m.isEmpty { model = m }
            if file.project == ProjectName.unknown, let cwd = payload["cwd"] as? String {
                file.project = ProjectName.from(cwd: cwd)
            }
        } else if !metaSeen, ByteSearch.contains("\"session_meta\"", inFirst: Self.typeWindow, of: line) {
            // The first session_meta is this thread's own; a forked helper
            // copies its parent's meta after it, which must not win.
            guard let object = ByteSearch.jsonObject(in: line),
                  object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any] else { return }
            metaSeen = true
            if let id = payload["id"] as? String, !id.isEmpty { file.sessionID = id }
            if let parent = (payload["forked_from_id"] as? String) ?? (payload["parent_thread_id"] as? String), !parent.isEmpty {
                file.parentSessionID = parent
            }
            if let cwd = payload["cwd"] as? String { file.project = ProjectName.from(cwd: cwd) }
            if model == nil, let m = payload["model"] as? String, !m.isEmpty { model = m }
        }
    }

    private mutating func consumeTokenCount(_ line: UnsafeRawBufferPointer) {
        guard let object = ByteSearch.jsonObject(in: line),
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let stamp = object["timestamp"] as? String,
              let at = FastISO8601.parse(stamp)
        else { return }
        if let rate = payload["rate_limits"] as? [String: Any], let plan = rate["plan_type"] as? String, !plan.isEmpty {
            if file.planTypeAt.map({ at >= $0 }) ?? true {
                file.planType = plan
                file.planTypeAt = at
            }
        }
        guard let info = payload["info"] as? [String: Any],
              let totalDict = info["total_token_usage"] as? [String: Any] else { return }
        let total = RawUsage(totalDict)
        let last = (info["last_token_usage"] as? [String: Any]).map(RawUsage.init)
        var delta: RawUsage
        if let previousTotal {
            delta = total - previousTotal
            if delta.anyNegative {
                // The running total went backwards: count the last request.
                delta = last ?? RawUsage(input: 0, cached: 0, cacheWrite: 0, output: 0, reasoning: 0)
            }
        } else {
            delta = total
        }
        previousTotal = total
        guard !delta.isZero else { return }
        let modelID = model ?? "unknown"
        let counts = delta.counts
        let long = APIPricing.isLongContext(model: modelID, promptTokens: counts.prompt)
        let event = TokenEvent(at: at, model: modelID, counts: counts, longContext: long)
        // Merge into the previous event when it is the same model, minute
        // and price tier: a long session writes thousands of these.
        if var lastEvent = file.events.last,
           lastEvent.model == modelID, lastEvent.longContext == long,
           Int(lastEvent.at.timeIntervalSince1970 / 60) == Int(at.timeIntervalSince1970 / 60) {
            lastEvent.counts += counts
            lastEvent.at = max(lastEvent.at, at)
            file.events[file.events.count - 1] = lastEvent
        } else {
            file.events.append(event)
        }
    }
}

// MARK: - Gemini CLI

/// Reads one Gemini CLI chat (`~/.gemini/tmp/<project>/chats/session-*.jsonl`,
/// or the older single-object `session-*.json`). Each `gemini` message
/// carries `tokens` {input, output, cached, thoughts, tool, total} in the
/// Gemini API's terms: `input` (prompt) includes `cached`; `thoughts` and
/// `tool` are counted beside it. A message is rewritten in place as it
/// streams, so the same id can appear more than once; the last one counts.
///
/// Antigravity keeps its conversations in protobuf blobs with no published
/// schema, so its usage is not read here.
struct GeminiChatParser: Sendable {
    private(set) var file: TokenLogFile
    private var index: [String: Int] = [:]

    init(fallbackSessionID: String, project: String) {
        file = TokenLogFile(tool: .gemini, sessionID: fallbackSessionID, project: project)
    }

    mutating func consume(_ line: UnsafeRawBufferPointer) {
        if ByteSearch.contains("\"tokens\"", in: line) {
            guard let object = ByteSearch.jsonObject(in: line) else { return }
            consume(message: object)
        } else if file.events.isEmpty, ByteSearch.contains("\"sessionId\"", in: line),
                  let object = ByteSearch.jsonObject(in: line),
                  let id = object["sessionId"] as? String, !id.isEmpty {
            file.sessionID = id
        }
    }

    /// The older format: one JSON document with a `messages` array.
    mutating func consume(document: [String: Any]) {
        if let id = document["sessionId"] as? String, !id.isEmpty { file.sessionID = id }
        for message in document["messages"] as? [[String: Any]] ?? [] {
            consume(message: message)
        }
    }

    private mutating func consume(message object: [String: Any]) {
        guard object["type"] as? String == "gemini",
              let tokens = object["tokens"] as? [String: Any],
              let stamp = object["timestamp"] as? String,
              let at = FastISO8601.parse(stamp)
        else { return }
        let prompt = tokens.int("input")
        let cached = min(prompt, tokens.int("cached"))
        let thoughts = tokens.int("thoughts")
        let counts = TokenCounts(
            input: max(0, prompt - cached) + tokens.int("tool"),
            cacheRead: cached,
            output: tokens.int("output") + thoughts,
            reasoning: thoughts
        )
        guard !counts.isZero else { return }
        let model = (object["model"] as? String) ?? "unknown"
        let event = TokenEvent(at: at, model: model, counts: counts,
                               longContext: APIPricing.isLongContext(model: model, promptTokens: counts.prompt))
        if let id = object["id"] as? String, !id.isEmpty {
            if let existing = index[id] {
                file.events[existing] = event
                return
            }
            index[id] = file.events.count
        }
        file.events.append(event)
    }

    /// The Gemini CLI names each project's temp folder after the project
    /// (older versions used a hash) and keeps the full path in `.project_root`.
    static func projectName(forTempFolder folder: URL) -> String {
        let marker = folder.appendingPathComponent(".project_root")
        if let root = try? String(contentsOf: marker, encoding: .utf8) {
            let trimmed = root.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return ProjectName.from(cwd: trimmed) }
        }
        let name = folder.lastPathComponent
        let isHash = name.count >= 32 && name.allSatisfy { $0.isHexDigit }
        if isHash { return ProjectName.unknown }
        if name == URL(fileURLWithPath: NSHomeDirectory()).lastPathComponent { return ProjectName.home }
        return name
    }
}
