import Darwin
import Foundation

struct OllamaTokenSummary: Equatable, Sendable {
    var promptTokens = 0
    var generatedTokens = 0
    var todayTokens = 0
    var weekTokens = 0
    var requestCount = 0
    var latestAt: Date?
    var modelTokens: [String: Int] = [:]

    var totalTokens: Int { promptTokens + generatedTokens }
}

/// Local model (Ollama) tokens, read from the log of the Ollama server that
/// is actually running, wherever it writes: the Ollama app's
/// `~/.ollama/logs/server*.log`, Homebrew's or a LaunchAgent's own log file
/// (found from the running `ollama serve` process), or
/// `CODEX_USAGE_HUD_OLLAMA_LOG`. Each file is read once, then only the bytes
/// appended since, so a busy server's log is followed live and cheaply.
/// Files are tracked by inode, so a rotated log is never counted twice.
enum LocalModelUsageReader {
    /// A first read of a very large log starts this far from its end.
    static let firstReadLimit: UInt64 = 64 * 1024 * 1024

    private static let tracker = LocalLogTracker()

    /// This Mac's own Ollama app logs.
    static var primaryLogDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ollama/logs")
    }

    static func loadSnapshot() -> UsageSnapshot? {
        let running = OllamaProcess.serverLogPaths()
        let urls = candidateLogURLs(running: running.logs)
        guard !urls.isEmpty || running.isRunning else { return nil }
        let result = tracker.read(urls: urls)
        return snapshot(from: result.summary, sources: urls, partial: result.partial, running: running.isRunning)
    }

    /// Every log that may hold this Mac's Ollama requests.
    static func candidateLogURLs(running: [URL]) -> [URL] {
        var urls = logURLs(in: primaryLogDirectory)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let known = [
            home.appendingPathComponent("Library/Logs/ollama.log"),
            URL(fileURLWithPath: "/opt/homebrew/var/log/ollama.log"),
            URL(fileURLWithPath: "/usr/local/var/log/ollama.log"),
        ]
        var extra = known + running
        if let override = ProcessInfo.processInfo.environment["CODEX_USAGE_HUD_OLLAMA_LOG"], !override.isEmpty {
            extra.append(URL(fileURLWithPath: NSString(string: override).expandingTildeInPath))
        }
        for url in extra where FileManager.default.isReadableFile(atPath: url.path) {
            urls.append(url)
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
    }

    static func snapshot(from summary: OllamaTokenSummary, sources: [URL], partial: Bool, running: Bool) -> UsageSnapshot {
        let total = Double(summary.totalTokens)
        let contributors: [UsageSnapshot.Contributor] = [
            ("Prompt", summary.promptTokens),
            ("Replies", summary.generatedTokens)
        ].compactMap { label, value in
            guard value > 0, total > 0 else { return nil }
            return UsageSnapshot.Contributor(percent: Double(value) / total * 100, label: label)
        }
        let models = summary.modelTokens
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { UsageSnapshot.RankedItem(name: $0.key, percent: total > 0 ? Double($0.value) / total * 100 : 0) }

        // The count is re-read from the logs on every refresh, so it is as of now.
        let readAt = ISO8601DateFormatter().string(from: Date())
        var note = "Exact prompt and reply token counts from the running Ollama server's log on this Mac."
        if partial { note += " One log was too large to read whole; older history is left out." }
        if summary.requestCount == 0 { note += running ? " Ollama is running; no requests logged yet." : "" }
        return UsageSnapshot(
            provider: "local",
            displayName: "Local Models",
            source: "Ollama logs on this Mac",
            sourceKind: "local_runtime_log",
            confidence: partial ? "medium" : "high",
            confidenceNote: note,
            updatedAt: readAt,
            capturedAt: readAt,
            eventAt: summary.latestAt.map { ISO8601DateFormatter().string(from: $0) },
            session: UsageSnapshot.SessionMetrics(
                costUSD: 0,
                durationAPI: nil,
                durationWall: nil,
                codeAdded: nil,
                codeRemoved: nil,
                input: summary.promptTokens,
                output: summary.generatedTokens,
                cacheRead: nil,
                cacheWrite: nil,
                reasoningOutput: nil,
                total: summary.totalTokens,
                lastInput: nil,
                lastOutput: nil,
                lastCacheRead: nil,
                lastReasoningOutput: nil,
                lastTotal: nil,
                contextWindow: nil,
                todayTotal: summary.todayTokens,
                weekTotal: summary.weekTokens,
                requestCount: summary.requestCount
            ),
            contributors: contributors,
            skills: models,
            extraUsage: "this Mac",
            sourcePath: sources.first?.path ?? primaryLogDirectory.path
        )
    }

    /// Whole-text parse, for tests and one-off reads.
    static func parse(
        logs: [String],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> OllamaTokenSummary? {
        var requests: [OllamaRequest] = []
        for log in logs {
            var cursor = OllamaLogCursor(calendar: calendar)
            requests += cursor.feed(log)
        }
        let summary = summarize(requests, now: now, calendar: calendar)
        return summary.totalTokens > 0 ? summary : nil
    }

    static func summarize(_ requests: [OllamaRequest], now: Date = Date(), calendar: Calendar = .current) -> OllamaTokenSummary {
        var summary = OllamaTokenSummary()
        let startOfToday = calendar.startOfDay(for: now)
        let weekAgo = now.addingTimeInterval(-7 * 24 * 60 * 60)
        for request in requests {
            let total = request.prompt + request.generated
            summary.promptTokens += request.prompt
            summary.generatedTokens += request.generated
            summary.requestCount += 1
            summary.modelTokens[request.model, default: 0] += total
            if request.date >= startOfToday { summary.todayTokens += total }
            if request.date >= weekAgo { summary.weekTokens += total }
            if summary.latestAt.map({ request.date > $0 }) ?? true { summary.latestAt = request.date }
        }
        return summary
    }

    /// Every `server*.log` in the Ollama log directory, oldest name first.
    static func logURLs(in directory: URL) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.filter {
            $0.pathExtension == "log" && $0.deletingPathExtension().lastPathComponent.hasPrefix("server")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

struct OllamaRequest: Equatable, Sendable {
    var date: Date
    var prompt: Int
    var generated: Int
    var model: String
}

/// Line parser that can be fed a log in pieces. Token counts come from the
/// runner's `prompt eval time` / `eval time` lines; the request's time comes
/// from the `[GIN]` line written when the request finishes.
struct OllamaLogCursor {
    private var activeModel = "Unknown local model"
    private var promptByTask: [Int: Int] = [:]
    private var pending: [(prompt: Int, generated: Int, model: String)] = []
    private let formatter: DateFormatter

    init(calendar: Calendar = .current) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy/MM/dd - HH:mm:ss"
        self.formatter = formatter
    }

    mutating func feed(_ text: String) -> [OllamaRequest] {
        var out: [OllamaRequest] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let request = feedLine(Substring(raw)) { out.append(request) }
        }
        return out
    }

    private mutating func feedLine(_ line: Substring) -> OllamaRequest? {
        if let model = Self.modelName(from: line) {
            activeModel = model
            return nil
        }
        if line.contains("eval time") {
            guard let task = Self.taskID(from: line), let tokens = Self.timingTokens(from: line) else { return nil }
            if line.contains("prompt eval time") {
                promptByTask[task] = tokens
            } else {
                pending.append((promptByTask.removeValue(forKey: task) ?? 0, tokens, activeModel))
                if pending.count > 256 { pending.removeFirst(pending.count - 256) }
            }
            return nil
        }
        guard Self.isInferenceCompletion(line), !pending.isEmpty, let date = ginDate(from: line) else { return nil }
        let request = pending.removeFirst()
        return OllamaRequest(date: date, prompt: request.prompt, generated: request.generated, model: request.model)
    }

    private static func modelName(from line: Substring) -> String? {
        let marker = "model=registry.ollama.ai/"
        guard let range = line.range(of: marker) else { return nil }
        let raw = String(line[range.upperBound...].prefix { !$0.isWhitespace })
        guard !raw.isEmpty else { return nil }
        return raw.hasPrefix("library/") ? String(raw.dropFirst("library/".count)) : raw
    }

    private static func taskID(from line: Substring) -> Int? {
        guard let taskRange = line.range(of: "task ") else { return nil }
        let digits = line[taskRange.upperBound...].drop { $0 == " " }.prefix { $0.isNumber }
        return Int(digits)
    }

    private static func timingTokens(from line: Substring) -> Int? {
        guard let slash = line.range(of: "/", options: .backwards),
              let tokens = line.range(of: "tokens", range: slash.upperBound..<line.endIndex)
        else { return nil }
        return Int(line[slash.upperBound..<tokens.lowerBound].trimmingCharacters(in: .whitespaces))
    }

    private static func isInferenceCompletion(_ line: Substring) -> Bool {
        guard line.hasPrefix("[GIN]"), line.contains("POST") else { return false }
        return ["/api/chat", "/api/generate", "/v1/chat/completions", "/v1/completions", "/v1/responses", "/v1/messages"]
            .contains { line.contains($0) }
    }

    private func ginDate(from line: Substring) -> Date? {
        guard let start = line.range(of: "[GIN] ")?.upperBound,
              let end = line.range(of: " |", range: start..<line.endIndex)?.lowerBound
        else { return nil }
        return formatter.date(from: String(line[start..<end]))
    }
}

/// Follows each log by inode: the first look reads the file (up to
/// `firstReadLimit` from its end), later looks read only appended bytes.
private final class LocalLogTracker: @unchecked Sendable {
    private struct FileState {
        var offset: UInt64
        var cursor: OllamaLogCursor
        var requests: [OllamaRequest]
        var partial: Bool
    }

    private let lock = NSLock()
    private var files: [String: FileState] = [:]

    func read(urls: [URL], now: Date = Date()) -> (summary: OllamaTokenSummary, partial: Bool) {
        lock.lock()
        defer { lock.unlock() }
        var live = Set<String>()
        let keepAfter = now.addingTimeInterval(-8 * 24 * 60 * 60)
        for url in urls {
            var info = stat()
            guard stat(url.path, &info) == 0 else { continue }
            let key = "\(info.st_dev):\(info.st_ino)"
            guard live.insert(key).inserted else { continue }
            let size = UInt64(max(0, info.st_size))
            var state = files[key] ?? FileState(offset: 0, cursor: OllamaLogCursor(), requests: [], partial: false)
            if size < state.offset {
                state = FileState(offset: 0, cursor: OllamaLogCursor(), requests: [], partial: false)
            }
            if state.offset == 0, size > LocalModelUsageReader.firstReadLimit {
                state.offset = size - LocalModelUsageReader.firstReadLimit
                state.partial = true
            }
            if size > state.offset, let handle = try? FileHandle(forReadingFrom: url) {
                defer { try? handle.close() }
                try? handle.seek(toOffset: state.offset)
                let data = (try? handle.read(upToCount: Int(size - state.offset))) ?? Data()
                // Only whole lines; a half-written last line waits for the next look.
                if let lastNewline = data.lastIndex(of: 0x0A) {
                    let chunk = data[data.startIndex...lastNewline]
                    let text = String(decoding: chunk, as: UTF8.self)
                    state.requests += state.cursor.feed(text)
                    state.offset += UInt64(chunk.count)
                }
            }
            state.requests.removeAll { $0.date < keepAfter }
            files[key] = state
        }
        files = files.filter { live.contains($0.key) }
        let all = files.values.flatMap(\.requests)
        return (LocalModelUsageReader.summarize(all, now: now), files.values.contains { $0.partial })
    }
}

/// The running `ollama serve` processes of this user, and the files their
/// output goes to. Looked up at most once a minute.
enum OllamaProcess {
    private static let cache = Cache()

    static func serverLogPaths(now: Date = Date()) -> (isRunning: Bool, logs: [URL]) {
        if let hit = cache.get(now: now) { return hit }
        let value = lookup()
        cache.set(value, at: now)
        return value
    }

    private static func lookup() -> (isRunning: Bool, logs: [URL]) {
        let pids = run("/usr/bin/pgrep", ["-U", String(getuid()), "-x", "ollama"])
            .split(whereSeparator: \.isNewline).compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        guard !pids.isEmpty else { return (false, []) }
        var logs: [URL] = []
        for pid in pids {
            // stdout and stderr of the server: where its log lines go.
            let out = run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "1,2", "-Fn"])
            for line in out.split(whereSeparator: \.isNewline) where line.hasPrefix("n/") {
                let path = String(line.dropFirst())
                if path.hasSuffix(".log") || path.contains("/Logs/") || path.contains("/log/") {
                    logs.append(URL(fileURLWithPath: path))
                }
            }
        }
        return (true, logs)
    }

    private static func run(_ tool: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (isRunning: Bool, logs: [URL])?
        private var at: Date?
        func get(now: Date) -> (isRunning: Bool, logs: [URL])? {
            lock.lock(); defer { lock.unlock() }
            guard let at, now.timeIntervalSince(at) < 60 else { return nil }
            return value
        }
        func set(_ newValue: (isRunning: Bool, logs: [URL]), at date: Date) {
            lock.lock(); value = newValue; at = date; lock.unlock()
        }
    }
}
