import Foundation

/// The command line built into the app binary. `main()` calls
/// `AgentCLI.runIfRequested()` before anything touches AppKit: a recognized
/// command runs, prints, and returns an exit code; anything else (no
/// arguments, `-psn_…`, `-NSDocumentRevisionsDebugMode`, …) returns nil and
/// the menu-bar app starts as usual.
///
/// Exit codes:
///   0  success (`room`: a plan has room now; `setup`: a lane has a reading or a job)
///   1  `room`: no plan clearly has room right now; `setup`: Set up could not run or installed nothing
///   2  usage error (unknown command or flag)
///   3  no readings yet (`status`, `room`, `lane`); no supported tool found (`setup`, `detect`)
enum AgentCLI {
    enum ExitCode {
        static let ok: Int32 = 0
        static let noRoom: Int32 = 1
        static let usage: Int32 = 2
        static let noReadings: Int32 = 3
    }

    struct IO {
        var out: (String) -> Void
        var err: (String) -> Void

        static let standard = IO(
            out: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
            err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        )
    }

    static let commands: Set<String> = ["status", "room", "lane", "spend", "activity", "setup", "detect", "mcp", "prompt", "schema", "help", "version"]
    static let topLevelFlags: Set<String> = ["--help", "-h", "--version", "-V"]

    /// What `setup` and `detect` call. Tests swap in a fixture detection and
    /// sandbox paths so no test touches ~/Library/LaunchAgents.
    struct SetupHooks {
        var detect: () -> DetectionSummary = { ToolDetection.detect() }
        var inspect: (DetectionSummary) -> AgentSetup.Report = { AgentSetup.detectReport(summary: $0) }
        var install: (DetectionSummary) -> AgentSetup.Report = { AgentSetup.runSetup(summary: $0) }

        static let live = SetupHooks()
    }

    /// The hook for `main()`. Nil means "not a CLI invocation; start the GUI".
    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Int32? {
        let args = Array(arguments.dropFirst())
        guard let first = args.first else { return nil }
        // Launch Services and Xcode pass dash arguments (-psn_0_123,
        // -NSDocumentRevisionsDebugMode YES); those belong to the GUI.
        if first.hasPrefix("-"), !topLevelFlags.contains(first) { return nil }
        return run(args)
    }

    static func run(
        _ args: [String],
        io: IO = .standard,
        summary: () -> AgentSummary = { AgentSummaryLoader.load() },
        executablePath: () -> String = { AgentPrompt.currentExecutablePath() },
        serveMCP: () -> Int32 = { MCPServer.serveStandardIO() },
        setup: SetupHooks = .live
    ) -> Int32 {
        guard let first = args.first else {
            io.out(help(executablePath: executablePath()))
            return ExitCode.ok
        }
        let command: String
        switch first {
        case "--help", "-h", "help": command = "help"
        case "--version", "-V", "version": command = "version"
        default: command = first
        }
        guard commands.contains(command) else {
            io.err("usage-hud: unknown command '\(first)'. Run 'usage-hud help' for the list.")
            return ExitCode.usage
        }

        var json = false
        var positional: [String] = []
        for arg in args.dropFirst() {
            if arg == "--json" { json = true; continue }
            if arg == "--help" || arg == "-h" {
                io.out(help(executablePath: executablePath()))
                return ExitCode.ok
            }
            if arg.hasPrefix("-") {
                io.err("usage-hud: unknown flag '\(arg)' for '\(command)'. Run 'usage-hud help'.")
                return ExitCode.usage
            }
            positional.append(arg)
        }

        switch command {
        case "help":
            io.out(help(executablePath: executablePath()))
            return ExitCode.ok
        case "version":
            io.out(versionLine())
            return ExitCode.ok
        case "prompt":
            guard positional.isEmpty, !json else { return usageError(io, "prompt takes no arguments.") }
            io.out(AgentPrompt.text(executablePath: executablePath(), home: UsagePaths.home.path))
            return ExitCode.ok
        case "schema":
            guard positional.isEmpty else { return usageError(io, "schema takes no arguments.") }
            io.out(prettyJSON(AgentSchema.summary))
            return ExitCode.ok
        case "mcp":
            guard positional.isEmpty, !json else { return usageError(io, "mcp takes no arguments.") }
            return serveMCP()
        case "status":
            guard positional.isEmpty else { return usageError(io, "status takes no arguments besides --json.") }
            let s = summary()
            io.out(json ? encodePretty(s) : AgentText.status(s))
            return s.hasAnyReading ? ExitCode.ok : ExitCode.noReadings
        case "room":
            guard positional.isEmpty else { return usageError(io, "room takes no arguments besides --json.") }
            let s = summary()
            io.out(json ? encodePretty(AgentRoomAdvice(summary: s)) : AgentText.room(s))
            if !s.hasAnyReading { return ExitCode.noReadings }
            return s.roomNow == nil ? ExitCode.noRoom : ExitCode.ok
        case "lane":
            guard positional.count == 1 else { return usageError(io, "lane needs one provider, e.g. 'usage-hud lane claude'.") }
            let s = summary()
            switch AgentText.resolveProvider(positional[0], in: s) {
            case .found(let lane):
                io.out(json ? encodePretty(lane) : AgentText.laneDetail(lane))
                return lane.usedPercent == nil && lane.windows.allSatisfy({ $0.usedPercent == nil })
                    ? ExitCode.noReadings : ExitCode.ok
            case .notTracked(let name):
                io.err("usage-hud: \(name) is not tracked on this Mac (turned off in Settings or not installed).")
                return ExitCode.usage
            case .unknown:
                io.err("usage-hud: unknown provider '\(positional[0])'. Use one of: \(ProviderCatalog.ids.joined(separator: ", ")).")
                return ExitCode.usage
            }
        case "spend":
            guard positional.isEmpty else { return usageError(io, "spend takes no arguments besides --json.") }
            let spend = AgentSpend.current().spend
            io.out(json ? AgentSpend.prettyJSON(spend) : AgentSpend.spendText(spend))
            return ExitCode.ok
        case "activity":
            guard positional.isEmpty else { return usageError(io, "activity takes no arguments besides --json.") }
            let activity = AgentSpend.current().activity
            io.out(json ? AgentSpend.prettyJSON(activity) : AgentSpend.activityText(activity))
            return ExitCode.ok
        case "detect":
            guard positional.isEmpty else { return usageError(io, "detect takes no arguments besides --json.") }
            let report = setup.inspect(setup.detect())
            io.out(json ? encodePretty(report) : AgentSetup.text(report))
            return setupExitCode(report)
        case "setup":
            guard positional.isEmpty else { return usageError(io, "setup takes no arguments besides --json.") }
            let report = setup.install(setup.detect())
            io.out(json ? encodePretty(report) : AgentSetup.text(report))
            return setupExitCode(report)
        default:
            return usageError(io, "unknown command '\(command)'.")
        }
    }

    static func setupExitCode(_ report: AgentSetup.Report) -> Int32 {
        if report.nothingFound { return ExitCode.noReadings }
        return report.ok ? ExitCode.ok : ExitCode.noRoom
    }

    private static func usageError(_ io: IO, _ message: String) -> Int32 {
        io.err("usage-hud: \(message) Run 'usage-hud help'.")
        return ExitCode.usage
    }

    static func versionLine() -> String {
        "\(AppInfo.productName) \(AppInfo.resolvedMarketingVersion) (agent schema \(AgentSummary.currentSchemaVersion); MCP \(MCPServer.supportedVersions.joined(separator: ", ")))"
    }

    static func help(executablePath: String) -> String {
        """
        \(AppInfo.productName) \(AppInfo.resolvedMarketingVersion): usage limits for the AI coding plans on this Mac.

        Usage: usage-hud <command> [--json]
        On this Mac: \(AgentPrompt.shellQuote(executablePath)) <command>

        Commands:
          status [--json]           Every plan: % used, pace, reset, reading age, and the verdict.
          room [--json]             One line: which plan has room right now.
          lane <provider> [--json]  One plan in detail (claude, codex, gemini, grok, local).
          spend [--json]            API value (not billed) and plan cost, per plan and in total.
          activity [--json]         Recent agent sessions: project, model, tokens, API value, burn rate.
          setup [--json]            What the Set up button does: find the coding tools on this Mac,
                                    install their background refresh, take a first reading. Prints one
                                    line per plan with the next action. No keys or logins needed.
          detect [--json]           Which coding tools are on this Mac, and what is already set up. Changes nothing.
          mcp                       Run the MCP server on stdin/stdout, for agent CLIs.
          prompt                    Print the setup prompt to paste into an agent session.
          schema                    Print the JSON Schema for `status --json`.
          help                      Show this help.
          --version                 Show the version.

        Exit codes:
          0  OK (room: a plan has room now; setup: a plan has a reading or a background job)
          1  room: no plan clearly has room right now; setup: Set up could not run or installed nothing
          2  usage error
          3  no readings yet (status, room, lane); no supported tool found (setup, detect). Run setup.

        Every command except setup reads Usage HUD's local state files only and never writes them.
        setup installs the same background jobs the Set up button installs. Nothing is ever sent anywhere.
        """
    }

    static func encodePretty<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    static func prettyJSON(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

/// Plain-text renderings shared by the CLI and the MCP tools' text content.
/// Short lines, plain words, written to be read by a person or an agent.
enum AgentText {
    static func status(_ s: AgentSummary) -> String {
        var lines = ["\(s.verdict.mode)  \(s.verdict.sentence)"]
        if let room = s.roomNow {
            lines.append("Room now: \(room.laneName), \(AgentRoomAdvice.describe(room)).")
        } else if s.hasAnyReading {
            lines.append("Room now: no plan clearly has room.")
        }
        guard !s.lanes.isEmpty else {
            lines.append("No plans are turned on. Open Usage HUD Settings to choose them.")
            return lines.joined(separator: "\n")
        }
        lines.append("")
        let nameWidth = max(6, s.lanes.map(\.name.count).max() ?? 6)
        for lane in s.lanes {
            lines.append(laneLine(lane, nameWidth: nameWidth))
        }
        return lines.joined(separator: "\n")
    }

    static func laneLine(_ lane: AgentSummary.Lane, nameWidth: Int = 0) -> String {
        let name = lane.name.padding(toLength: max(nameWidth, lane.name.count), withPad: " ", startingAt: 0)
        let window = (lane.window ?? "-").padding(toLength: 4, withPad: " ", startingAt: 0)
        let used = lane.usedPercent.map { AgentRoomAdvice.formatPercent($0) } ?? "-"
        let pace = AgentRoomAdvice.paceWords(lane.pace)
        var parts = ["\(name)  \(window) \(used.leftPad(5))  \(pace.padding(toLength: 13, withPad: " ", startingAt: 0))"]
        var tail: [String] = []
        if let resetsIn = lane.resetsIn { tail.append("resets in \(resetsIn)") }
        if let empty = lane.forecastEmptyAt, let date = UsageInsights.parseDate(empty) {
            tail.append("empty ~\(clockText(date))")
        }
        if lane.provider != "local" {
            if let age = lane.readingAge {
                tail.append("\(lane.confidence), \(age) old" + (lane.stale ? " (stale)" : ""))
            } else {
                tail.append("no reading")
            }
        }
        if lane.usedPercent == nil, let note = lane.note { tail.append(note) }
        parts.append(tail.joined(separator: " · "))
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    static func room(_ s: AgentSummary) -> String {
        if let room = s.roomNow {
            return "\(room.laneName) has the most room now: \(AgentRoomAdvice.describe(room))."
        }
        return AgentRoomAdvice.advice(summary: s)
    }

    static func laneDetail(_ lane: AgentSummary.Lane) -> String {
        var lines = [laneLine(lane)]
        if lane.usedPercent != nil, let note = lane.note { lines.append(note) }
        for w in lane.windows {
            let label = w.scope.map { "\(w.window) (\($0))" } ?? w.window
            var text = "  \(label): "
            if let used = w.usedPercent {
                text += "\(AgentRoomAdvice.formatPercent(used)) used, \(AgentRoomAdvice.paceWords(w.pace))"
            } else {
                text += w.state == "expired" ? "window reset, no new reading" : "no current reading"
            }
            if let resetsIn = w.resetsIn { text += ", resets in \(resetsIn)" }
            lines.append(text)
        }
        lines.append("  source: \(lane.source), confidence \(lane.confidence)")
        return lines.joined(separator: "\n")
    }

    static func clockText(_ date: Date, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = date.timeIntervalSince(now) < 20 * 3600 ? "h:mm a" : "EEE h a"
        return f.string(from: date)
    }

    enum ProviderMatch {
        case found(AgentSummary.Lane)
        case notTracked(String)
        case unknown
    }

    private static let aliases: [String: String] = [
        "claude code": "claude", "claude-code": "claude", "anthropic": "claude",
        "openai": "codex", "codex cli": "codex", "chatgpt": "codex",
        "gemini cli": "gemini", "gemini-cli": "gemini", "antigravity": "gemini", "google": "gemini",
        "grok build": "grok", "xai": "grok",
        "ollama": "local", "local models": "local",
    ]

    static func resolveProvider(_ raw: String, in summary: AgentSummary) -> ProviderMatch {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let id: String? = {
            if ProviderCatalog.definition(for: key) != nil { return key }
            if let alias = aliases[key] { return alias }
            return ProviderCatalog.all.first { $0.name.lowercased() == key }?.id
        }()
        guard let id else { return .unknown }
        if let lane = summary.lane(id) { return .found(lane) }
        return .notTracked(ProviderCatalog.definition(for: id)?.name ?? id)
    }
}

private extension String {
    func leftPad(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
