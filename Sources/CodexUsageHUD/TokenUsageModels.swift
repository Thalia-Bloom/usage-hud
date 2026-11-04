import Foundation

// ============================================================================
//  Token usage read from the coding tools' own session logs, in Swift.
//
//  Buyers have no Python or Node, so every number on the Value line and in
//  the Activity window comes from these readers. They keep numbers, model
//  ids and a project folder name only: never prompts, message text, file
//  paths or anything secret.
// ============================================================================

/// A coding tool whose local session logs carry token counts.
enum AgentTool: String, Codable, CaseIterable, Sendable, Comparable {
    case claude, codex, gemini

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        }
    }

    /// The panel lane this tool's spend belongs to.
    var provider: String { rawValue }

    static func < (lhs: AgentTool, rhs: AgentTool) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// Token buckets in billing terms. `input` is uncached input only; cache
/// writes and reads are separate because they are priced separately.
/// `output` includes reasoning/thinking tokens (billed as output);
/// `reasoning` is the informational subset.
struct TokenCounts: Codable, Equatable, Hashable, Sendable {
    var input = 0
    /// Cache writes at the short (5-minute) rate, or of unknown duration.
    var cacheWrite5m = 0
    /// Anthropic 1-hour cache writes (priced higher than 5-minute writes).
    var cacheWrite1h = 0
    var cacheRead = 0
    var output = 0
    var reasoning = 0

    var cacheWrite: Int { cacheWrite5m + cacheWrite1h }
    /// Everything the model processed, cache included.
    var total: Int { input + cacheWrite + cacheRead + output }
    /// The prompt side of one request: what a long-context tier looks at.
    var prompt: Int { input + cacheWrite + cacheRead }
    var isZero: Bool { total == 0 && reasoning == 0 }

    static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: lhs.input + rhs.input,
            cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m,
            cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            output: lhs.output + rhs.output,
            reasoning: lhs.reasoning + rhs.reasoning
        )
    }

    static func += (lhs: inout TokenCounts, rhs: TokenCounts) { lhs = lhs + rhs }

    /// Field-by-field maximum. Claude Code writes one line per content block
    /// and early lines can carry a partial output count, so the same
    /// message seen twice keeps the larger reading of each field.
    func fieldMax(_ other: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: max(input, other.input),
            cacheWrite5m: max(cacheWrite5m, other.cacheWrite5m),
            cacheWrite1h: max(cacheWrite1h, other.cacheWrite1h),
            cacheRead: max(cacheRead, other.cacheRead),
            output: max(output, other.output),
            reasoning: max(reasoning, other.reasoning)
        )
    }
}

/// One priced unit of usage: a request (Claude, Gemini) or the change in a
/// session's running total (Codex).
struct TokenEvent: Equatable, Sendable {
    var at: Date
    var model: String
    var counts: TokenCounts
    /// Claude: message id + request id, used to count a message once even
    /// when a resumed session copies it into another file.
    var key: String? = nil
    /// Claude fast mode (priced as a premium tier).
    var fast = false
    /// The request's prompt crossed the model's long-context price tier.
    var longContext = false
}

/// What one session log file contributed.
struct TokenLogFile: Equatable, Sendable {
    var tool: AgentTool
    var sessionID: String
    /// Codex helper threads point at the session that started them.
    var parentSessionID: String? = nil
    /// Last path component of the working folder, never the full path.
    var project: String = ProjectName.unknown
    /// Codex: the account's plan as the log reports it ("pro", "plus").
    var planType: String? = nil
    var planTypeAt: Date? = nil
    var events: [TokenEvent] = []
    /// Tells two files of one session apart (in-memory only, not a path).
    var fileKey: Int = 0

    var start: Date? { events.first?.at }
    var lastActive: Date? { events.map(\.at).max() }
}

// MARK: - Project names

/// Turns a working folder into the one word the UI may show. Full paths
/// never leave the reader; the home folder is not named after the user.
enum ProjectName {
    static let unknown = "Unknown project"
    static let home = "Home folder"
    static let temporary = "Temporary folder"
    /// Sessions started at "/" (launchers, background jobs).
    static let root = "No project folder"

    static func from(cwd: String?, homePath: String = NSHomeDirectory()) -> String {
        guard var path = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return unknown }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path == "/" { return root }
        let home = homePath.hasSuffix("/") ? String(homePath.dropLast()) : homePath
        if path == home { return Self.home }
        for root in ["/private/tmp", "/tmp", "/private/var/folders", "/var/folders"] where path == root || path.hasPrefix(root + "/") {
            return temporary
        }
        let parts = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        if let dot = parts.firstIndex(where: { $0 == ".claude" || $0 == ".codex" || $0 == ".grok" }),
           dot + 1 < parts.count, parts[dot + 1] == "worktrees" {
            let owner = "/" + parts.prefix(dot).joined(separator: "/")
            // An agent worktree inside a repo (`repo/.claude/worktrees/x`):
            // the repo is the project.
            if owner != home, dot > 0 { return parts[dot - 1] }
            // A tool-managed worktree under home
            // (`~/.codex/worktrees/<id>/<repo>`): the repo folder.
            if dot + 3 < parts.count { return parts[dot + 3] }
            return unknown
        }
        return parts.last ?? unknown
    }
}

// MARK: - Fast parsing helpers

/// ISO-8601 timestamps as the tools write them ("2026-09-29T22:18:48.560Z"),
/// parsed without a formatter: the readers see hundreds of thousands a scan.
enum FastISO8601 {
    static func parse(_ text: String) -> Date? {
        var text = text
        return text.withUTF8 { parse(UnsafeRawBufferPointer($0)) }
    }

    static func parse(_ bytes: UnsafeRawBufferPointer) -> Date? {
        let n = bytes.count
        guard n >= 19 else { return nil }
        func digits(_ start: Int, _ count: Int) -> Int? {
            var value = 0
            for i in start..<(start + count) {
                let c = bytes[i]
                guard c >= 48, c <= 57 else { return nil }
                value = value * 10 + Int(c - 48)
            }
            return value
        }
        guard let year = digits(0, 4), bytes[4] == 45, let month = digits(5, 2), bytes[7] == 45,
              let day = digits(8, 2), bytes[10] == 84 || bytes[10] == 32,
              let hour = digits(11, 2), bytes[13] == 58, let minute = digits(14, 2), bytes[16] == 58,
              let second = digits(17, 2),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
        else { return nil }
        var index = 19
        var fraction = 0.0
        if index < n, bytes[index] == 46 {
            index += 1
            var scale = 0.1
            while index < n, bytes[index] >= 48, bytes[index] <= 57 {
                fraction += Double(bytes[index] - 48) * scale
                scale /= 10
                index += 1
            }
        }
        var offset = 0
        guard index < n else {
            // No zone: the tools always write one; refuse rather than guess.
            return nil
        }
        let zone = bytes[index]
        if zone == 43 || zone == 45 {
            // +HH, +HHMM or +HH:MM
            guard index + 3 <= n, let oh = digits(index + 1, 2) else { return nil }
            var om = 0
            if index + 6 <= n, bytes[index + 3] == 58, let m = digits(index + 4, 2) { om = m }
            else if index + 5 <= n, let m = digits(index + 3, 2) { om = m }
            offset = (oh * 3600 + om * 60) * (zone == 43 ? 1 : -1)
        } else if zone != 90 && zone != 122 {
            return nil
        }
        // Days from civil (Howard Hinnant), proleptic Gregorian.
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        let seconds = Double(days * 86_400 + hour * 3600 + minute * 60 + second - offset) + fraction
        return Date(timeIntervalSince1970: seconds)
    }
}

/// Byte-level search over one JSONL line, so a reader can skip the lines it
/// does not need without decoding them.
enum ByteSearch {
    static func find(_ needle: StaticString, in buffer: UnsafeRawBufferPointer, from start: Int = 0) -> Int? {
        guard start < buffer.count, let base = buffer.baseAddress else { return nil }
        let length = needle.utf8CodeUnitCount
        guard length > 0, buffer.count - start >= length else { return nil }
        let found = memmem(base + start, buffer.count - start, needle.utf8Start, length)
        guard let found else { return nil }
        return base.distance(to: UnsafeRawPointer(found))
    }

    static func contains(_ needle: StaticString, in buffer: UnsafeRawBufferPointer) -> Bool {
        find(needle, in: buffer) != nil
    }

    /// Looks only at the first `limit` bytes. A line's type sits near its
    /// start, and libc's memmem over megabyte lines dominated a cold scan.
    static func contains(_ needle: StaticString, inFirst limit: Int, of buffer: UnsafeRawBufferPointer) -> Bool {
        let head = buffer.count > limit ? UnsafeRawBufferPointer(rebasing: buffer[0..<limit]) : buffer
        return find(needle, in: head) != nil
    }

    static func findLast(_ needle: StaticString, in buffer: UnsafeRawBufferPointer) -> Int? {
        var last: Int?
        var from = 0
        while let hit = find(needle, in: buffer, from: from) {
            last = hit
            from = hit + 1
        }
        return last
    }

    /// The plain string value that starts right after `key` (which ends with
    /// the opening quote, e.g. `"model":"`). Nil when the value carries an
    /// escape: ids and model names never do, so that is not a value we want.
    static func stringValue(after key: StaticString, in buffer: UnsafeRawBufferPointer, last: Bool = false, from: Int = 0) -> String? {
        guard let hit = last ? findLast(key, in: buffer) : find(key, in: buffer, from: from) else { return nil }
        let start = hit + key.utf8CodeUnitCount
        var end = start
        while end < buffer.count {
            let c = buffer[end]
            if c == 34 { break }        // "
            if c == 92 { return nil }   // backslash
            end += 1
        }
        guard end < buffer.count else { return nil }
        return String(decoding: UnsafeRawBufferPointer(rebasing: buffer[start..<end]), as: UTF8.self)
    }

    /// The JSON object that opens at `open` (a `{`), matched through strings.
    static func objectRange(openingAt open: Int, in buffer: UnsafeRawBufferPointer) -> Range<Int>? {
        guard open < buffer.count, buffer[open] == 123 else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var i = open
        while i < buffer.count {
            let c = buffer[i]
            if inString {
                if escaped { escaped = false }
                else if c == 92 { escaped = true }
                else if c == 34 { inString = false }
            } else if c == 34 {
                inString = true
            } else if c == 123 {
                depth += 1
            } else if c == 125 {
                depth -= 1
                if depth == 0 { return open..<(i + 1) }
            }
            i += 1
        }
        return nil
    }

    static func jsonObject(in buffer: UnsafeRawBufferPointer, range: Range<Int>? = nil) -> [String: Any]? {
        let slice = range.map { UnsafeRawBufferPointer(rebasing: buffer[$0]) } ?? buffer
        guard let base = slice.baseAddress, slice.count > 0 else { return nil }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: slice.count, deallocator: .none)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Calls `body` with every complete line in `buffer` from `start`.
    /// Returns the offset just past the last newline, where a later read of
    /// a growing file picks up.
    @discardableResult
    static func forEachLine(in buffer: UnsafeRawBufferPointer, from start: Int = 0, _ body: (UnsafeRawBufferPointer) -> Void) -> Int {
        guard let base = buffer.baseAddress else { return start }
        var lineStart = start
        while lineStart < buffer.count {
            guard let newline = memchr(base + lineStart, 10, buffer.count - lineStart) else { break }
            let lineEnd = base.distance(to: UnsafeRawPointer(newline))
            if lineEnd > lineStart {
                body(UnsafeRawBufferPointer(rebasing: buffer[lineStart..<lineEnd]))
            }
            lineStart = lineEnd + 1
        }
        return lineStart
    }
}

extension Dictionary where Key == String, Value == Any {
    func int(_ key: String) -> Int {
        if let v = self[key] as? Int { return v }
        if let v = self[key] as? Double, v.isFinite { return Int(v) }
        if let v = self[key] as? NSNumber { return v.intValue }
        return 0
    }
}
