import Foundation

/// Where each tool keeps its session logs.
struct TokenLogRoots: Equatable, Sendable {
    var claudeProjects: [URL] = []
    var codexSessions: [URL] = []
    var geminiTmp: URL?
    /// Claude Code's `~/.claude.json`, read only for its plan fields.
    var claudeConfig: URL?

    static let none = TokenLogRoots()

    var isEmpty: Bool { claudeProjects.isEmpty && codexSessions.isEmpty && geminiTmp == nil }

    /// `CODEX_USAGE_HUD_TOKEN_LOGS`: unset reads the live logs, except in an
    /// isolated (fixture) state dir where it reads nothing; `live` reads the
    /// live logs anyway; `off` reads nothing; any other value is a fixture
    /// folder holding `claude/projects`, `codex/sessions`, `gemini/tmp` and
    /// `claude.json`.
    static var current: TokenLogRoots {
        resolve(
            env: ProcessInfo.processInfo.environment,
            home: UsagePaths.home,
            isolated: UsagePaths.isIsolatedStateDir
        )
    }

    static func resolve(env: [String: String], home: URL, isolated: Bool) -> TokenLogRoots {
        let setting = env["CODEX_USAGE_HUD_TOKEN_LOGS"]?.trimmingCharacters(in: .whitespaces) ?? ""
        switch setting {
        case "off": return .none
        case "live": return live(env: env, home: home)
        case "": return isolated ? .none : live(env: env, home: home)
        default:
            let root = URL(fileURLWithPath: NSString(string: setting).expandingTildeInPath)
            return TokenLogRoots(
                claudeProjects: [root.appendingPathComponent("claude/projects")],
                codexSessions: [root.appendingPathComponent("codex/sessions")],
                geminiTmp: root.appendingPathComponent("gemini/tmp"),
                claudeConfig: root.appendingPathComponent("claude.json")
            )
        }
    }

    static func live(env: [String: String], home: URL) -> TokenLogRoots {
        func expand(_ path: String) -> URL { URL(fileURLWithPath: NSString(string: path).expandingTildeInPath) }
        // Claude Code honours CLAUDE_CONFIG_DIR (comma-separated); newer
        // installs may also use ~/.config/claude.
        var claudeDirs: [URL] = []
        if let configured = env["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            claudeDirs = configured.split(separator: ",").map { expand(String($0).trimmingCharacters(in: .whitespaces)) }
        } else {
            claudeDirs = [home.appendingPathComponent(".claude"), home.appendingPathComponent(".config/claude")]
        }
        let codexHome = env["CODEX_HOME"].flatMap { $0.isEmpty ? nil : expand($0) } ?? home.appendingPathComponent(".codex")
        return TokenLogRoots(
            claudeProjects: claudeDirs.map { $0.appendingPathComponent("projects") },
            // Archiving a Codex session moves its file; it is counted once.
            codexSessions: [codexHome.appendingPathComponent("sessions"), codexHome.appendingPathComponent("archived_sessions")],
            geminiTmp: home.appendingPathComponent(".gemini/tmp"),
            claudeConfig: home.appendingPathComponent(".claude.json")
        )
    }
}

/// Everything one scan read.
struct TokenScan: Sendable {
    var files: [TokenLogFile]
    var scannedAt: Date
    /// Tools whose log folder exists on this Mac.
    var toolsWithLogs: Set<AgentTool>
    var roots: TokenLogRoots
    /// Seconds the scan took, for the tests' CPU budget and diagnostics.
    var duration: TimeInterval
    var filesParsed: Int
}

/// Reads the tools' session logs, newest first, and keeps what it read.
///
/// A file is re-read only when its size or modification time changes, and
/// a growing file (a running session) is read from where the last scan
/// stopped. Scans run at most once a minute; the panel's 5-second refresh
/// only ever reads the last result.
final class TokenUsageIndex: @unchecked Sendable {
    static let shared = TokenUsageIndex()

    /// Logs older than this are not read: the longest period shown is 30 days.
    static let maxAge: TimeInterval = 35 * 86_400
    /// Newest files kept per tool.
    static let maxFilesPerTool = 6_000
    static let rescanInterval: TimeInterval = 60
    /// After this long without a write, a log's parser state is dropped.
    static let settledAfter: TimeInterval = 6 * 3600

    private let stateLock = NSLock()
    private let scanLock = NSLock()
    private let queue = DispatchQueue(label: "com.codexusagehud.token-index", qos: .utility)
    private var cache: [String: CachedFile] = [:]
    private var latestScan: TokenScan?
    private var backgroundScanQueued = false

    private enum Parser: Sendable {
        case claude(ClaudeTranscriptParser)
        case codex(CodexRolloutParser)
        case gemini(GeminiChatParser)
        /// A file read to the end that is not followed any more (an old
        /// single-document Gemini chat, or a log quiet for hours).
        case finished(TokenLogFile)

        var isFinished: Bool {
            if case .finished = self { return true }
            return false
        }

        var file: TokenLogFile {
            switch self {
            case .claude(let p): return p.file
            case .codex(let p): return p.file
            case .gemini(let p): return p.file
            case .finished(let f): return f
            }
        }
    }

    private struct CachedFile: Sendable {
        var size: Int
        var modified: Double
        var inode: UInt64
        /// Byte offset just past the last complete line read.
        var offset: Int
        var parser: Parser
    }

    private struct Candidate {
        var url: URL
        var tool: AgentTool
        var size: Int
        var modified: Double
        var inode: UInt64
        var project: String?
    }

    /// The last finished scan, without starting one.
    func latest() -> TokenScan? {
        stateLock.lock(); defer { stateLock.unlock() }
        return latestScan
    }

    /// Starts a scan on the index's own queue when the last one is older
    /// than `rescanInterval`. Never blocks the caller.
    func refreshInBackground(roots: TokenLogRoots = .current, now: Date = Date()) {
        stateLock.lock()
        let fresh = latestScan.map { $0.roots == roots && now.timeIntervalSince($0.scannedAt) < Self.rescanInterval } ?? false
        if fresh || backgroundScanQueued {
            stateLock.unlock()
            return
        }
        backgroundScanQueued = true
        stateLock.unlock()
        queue.async { [self] in
            _ = scan(roots: roots, maxAge: Self.rescanInterval)
            stateLock.lock(); backgroundScanQueued = false; stateLock.unlock()
        }
    }

    /// The last scan if it is younger than `maxAge`, else a new one. Blocks.
    @discardableResult
    func scan(roots: TokenLogRoots = .current, now: Date = Date(), maxAge: TimeInterval = 0) -> TokenScan {
        scanLock.lock(); defer { scanLock.unlock() }
        if maxAge > 0, let last = latest(), last.roots == roots, now.timeIntervalSince(last.scannedAt) < maxAge {
            return last
        }
        let started = Date()
        let candidates = Self.candidates(roots: roots, now: now)
        stateLock.lock()
        var cache = self.cache
        stateLock.unlock()

        var files: [TokenLogFile] = []
        var keep: [String: CachedFile] = [:]
        var parsed = 0
        for candidate in candidates.files {
            let path = candidate.url.path
            var entry: CachedFile
            if let hit = cache.removeValue(forKey: path), hit.inode == candidate.inode {
                if hit.size == candidate.size && hit.modified == candidate.modified {
                    entry = hit
                } else if candidate.size > hit.size, let grown = Self.continueReading(hit, url: candidate.url, size: candidate.size, modified: candidate.modified) {
                    entry = grown
                    parsed += 1
                } else {
                    guard let fresh = Self.read(candidate) else { continue }
                    entry = fresh
                    parsed += 1
                }
            } else {
                guard let fresh = Self.read(candidate) else { continue }
                entry = fresh
                parsed += 1
            }
            // A log that has been quiet for hours is done: keep its result,
            // drop the parser's de-dup index. If it ever grows again it is
            // read from the start.
            if candidate.modified < now.timeIntervalSince1970 - Self.settledAfter, !entry.parser.isFinished {
                entry.parser = .finished(entry.parser.file)
            }
            keep[path] = entry
            var file = entry.parser.file
            file.fileKey = path.hashValue
            if !file.events.isEmpty { files.append(file) }
        }
        let scan = TokenScan(
            files: files,
            scannedAt: now,
            toolsWithLogs: candidates.tools,
            roots: roots,
            duration: Date().timeIntervalSince(started),
            filesParsed: parsed
        )
        stateLock.lock()
        self.cache = keep
        latestScan = scan
        stateLock.unlock()
        return scan
    }

    /// Drops everything read so far (tests).
    func reset() {
        scanLock.lock(); defer { scanLock.unlock() }
        stateLock.lock(); cache = [:]; latestScan = nil; stateLock.unlock()
    }

    // MARK: Finding files

    private static func candidates(roots: TokenLogRoots, now: Date) -> (files: [Candidate], tools: Set<AgentTool>) {
        let cutoff = now.timeIntervalSince1970 - maxAge
        var tools = Set<AgentTool>()
        var all: [Candidate] = []
        let fm = FileManager.default

        var claude: [Candidate] = []
        for root in roots.claudeProjects where fm.fileExists(atPath: root.path) {
            tools.insert(.claude)
            claude += listFiles(under: root, tool: .claude, cutoff: cutoff) { $0.pathExtension == "jsonl" }
        }
        all += newest(claude)

        var codex: [Candidate] = []
        for root in roots.codexSessions where fm.fileExists(atPath: root.path) {
            if root.lastPathComponent == "sessions" { tools.insert(.codex) }
            codex += listFiles(under: root, tool: .codex, cutoff: cutoff) {
                $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-")
            }
        }
        all += newest(codex)

        if let tmp = roots.geminiTmp, let projects = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
            var gemini: [Candidate] = []
            for folder in projects {
                let chats = folder.appendingPathComponent("chats")
                guard fm.fileExists(atPath: chats.path) else { continue }
                tools.insert(.gemini)
                let project = GeminiChatParser.projectName(forTempFolder: folder)
                gemini += listFiles(under: chats, tool: .gemini, cutoff: cutoff, recursive: false) {
                    ($0.pathExtension == "jsonl" || $0.pathExtension == "json") && $0.lastPathComponent.hasPrefix("session-")
                }.map { var c = $0; c.project = project; return c }
            }
            all += newest(gemini)
        }
        return (all, tools)
    }

    private static func newest(_ files: [Candidate]) -> [Candidate] {
        Array(files.sorted { $0.modified > $1.modified }.prefix(maxFilesPerTool))
    }

    private static func listFiles(under root: URL, tool: AgentTool, cutoff: Double, recursive: Bool = true, include: (URL) -> Bool) -> [Candidate] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .fileResourceIdentifierKey]
        var out: [Candidate] = []
        func consider(_ url: URL) {
            guard include(url),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate?.timeIntervalSince1970,
                  modified >= cutoff
            else { return }
            out.append(Candidate(url: url, tool: tool, size: values.fileSize ?? 0, modified: modified,
                                 inode: inode(of: url)))
        }
        if recursive {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]
            ) else { return [] }
            for case let url as URL in enumerator {
                // Codex keeps YYYY/MM/DD folders: skip whole months and days
                // that end before the cutoff.
                if tool == .codex, isOldDateFolder(url, cutoff: cutoff) {
                    enumerator.skipDescendants()
                    continue
                }
                consider(url)
            }
        } else {
            for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys)) ?? [] {
                consider(url)
            }
        }
        return out
    }

    /// `sessions/2026/08` or `sessions/2026/08/14` wholly before the cutoff.
    private static func isOldDateFolder(_ url: URL, cutoff: Double) -> Bool {
        let parts = url.pathComponents.suffix(3)
        guard let last = parts.last, Int(last) != nil else { return false }
        let numbers = parts.compactMap { Int($0) }
        var components = DateComponents()
        if numbers.count == 3, numbers[0] > 1999 {
            components.year = numbers[0]; components.month = numbers[1]; components.day = numbers[2] + 1
        } else if numbers.count >= 2, let year = numbers.dropLast().last, year > 1999 {
            components.year = year; components.month = numbers.last! + 1; components.day = 1
        } else {
            return false
        }
        // One day of slack for time zones.
        guard let end = Calendar(identifier: .gregorian).date(from: components) else { return false }
        return end.timeIntervalSince1970 + 86_400 < cutoff
    }

    private static func inode(of url: URL) -> UInt64 {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return 0 }
        return UInt64(info.st_ino)
    }

    // MARK: Reading

    private static func newParser(for candidate: Candidate) -> Parser {
        let stem = candidate.url.deletingPathExtension().lastPathComponent
        switch candidate.tool {
        case .claude:
            return .claude(ClaudeTranscriptParser(fallbackSessionID: stem))
        case .codex:
            return .codex(CodexRolloutParser(fallbackSessionID: stem))
        case .gemini:
            return .gemini(GeminiChatParser(fallbackSessionID: stem, project: candidate.project ?? ProjectName.unknown))
        }
    }

    private static func read(_ candidate: Candidate) -> CachedFile? {
        var parser = newParser(for: candidate)
        if candidate.tool == .gemini, candidate.url.pathExtension == "json" {
            // The older Gemini CLI wrote one JSON document per chat.
            guard let data = try? Data(contentsOf: candidate.url) else { return nil }
            var gemini = GeminiChatParser(fallbackSessionID: candidate.url.deletingPathExtension().lastPathComponent,
                                          project: candidate.project ?? ProjectName.unknown)
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                gemini.consume(document: object)
            }
            parser = .finished(gemini.file)
            return CachedFile(size: data.count, modified: candidate.modified, inode: candidate.inode, offset: data.count, parser: parser)
        }
        guard let read = stream(candidate.url, from: 0, into: &parser) else { return nil }
        return CachedFile(size: read.size, modified: candidate.modified, inode: candidate.inode, offset: read.offset, parser: parser)
    }

    /// Reads only the bytes a growing file gained since the last scan.
    private static func continueReading(_ cached: CachedFile, url: URL, size: Int, modified: Double) -> CachedFile? {
        if case .finished = cached.parser { return nil }
        var next = cached
        guard let read = stream(url, from: cached.offset, into: &next.parser) else { return nil }
        next.offset = read.offset
        next.size = read.size
        next.modified = modified
        return next
    }

    static let chunkSize = 4 << 20

    /// Feeds every complete line from `offset` to the end of the file
    /// through `parser`, in large sequential reads: memory-mapping made a
    /// cold scan several times slower (one page fault per 16 KB). Returns
    /// the offset just past the last complete line and the bytes seen.
    private static func stream(_ url: URL, from offset: Int, into parser: inout Parser) -> (offset: Int, size: Int)? {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        // One pass over old logs: don't push the user's own files out of
        // the page cache to keep these.
        _ = fcntl(fd, F_NOCACHE, 1)
        if offset > 0, lseek(fd, off_t(offset), SEEK_SET) < 0 { return nil }
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var filled = 0
        var base = offset
        while true {
            if filled == buffer.count {
                // One line longer than the buffer: grow it.
                buffer.append(contentsOf: repeatElement(0, count: buffer.count))
            }
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress! + filled, raw.count - filled)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { break }
            filled += count
            // JSONSerialization hands back autoreleased objects; drain them
            // per chunk or a cold scan holds every decoded line at once.
            let used = autoreleasepool {
                buffer.withUnsafeBytes { raw in
                    feed(&parser, UnsafeRawBufferPointer(rebasing: raw[0..<filled]), from: 0)
                }
            }
            if used > 0 {
                buffer.withUnsafeMutableBytes { raw in
                    _ = memmove(raw.baseAddress!, raw.baseAddress! + used, filled - used)
                }
                filled -= used
                base += used
            }
        }
        return (base, base + filled)
    }

    private static func feed(_ parser: inout Parser, _ buffer: UnsafeRawBufferPointer, from start: Int) -> Int {
        // Take the parser out of the enum before mutating it, so its arrays
        // stay uniquely referenced and grow in place instead of copying.
        let placeholder = Parser.finished(TokenLogFile(tool: .claude, sessionID: ""))
        switch parser {
        case .claude(var p):
            parser = placeholder
            let end = ByteSearch.forEachLine(in: buffer, from: start) { p.consume($0) }
            parser = .claude(p)
            return end
        case .codex(var p):
            parser = placeholder
            let end = ByteSearch.forEachLine(in: buffer, from: start) { p.consume($0) }
            parser = .codex(p)
            return end
        case .gemini(var p):
            parser = placeholder
            let end = ByteSearch.forEachLine(in: buffer, from: start) { p.consume($0) }
            parser = .gemini(p)
            return end
        case .finished:
            return buffer.count
        }
    }
}
