import XCTest
@testable import CodexUsageHUD

private typealias F = AgentFixtures

final class AgentCLITests: XCTestCase {
    private final class Capture {
        var out: [String] = []
        var err: [String] = []
        var io: AgentCLI.IO { AgentCLI.IO(out: { self.out.append($0) }, err: { self.err.append($0) }) }
        var stdout: String { out.joined(separator: "\n") }
    }

    private func run(
        _ args: [String],
        snapshots: [UsageSnapshot] = F.fleet,
        mcp: @escaping () -> Int32 = { 0 },
        setup: AgentCLI.SetupHooks = .live
    ) -> (Int32, Capture) {
        let capture = Capture()
        let code = AgentCLI.run(
            args,
            io: capture.io,
            summary: { F.summary(snapshots) },
            executablePath: { "/Applications/Usage HUD.app/Contents/MacOS/CodexUsageHUD" },
            serveMCP: mcp,
            setup: setup
        )
        return (code, capture)
    }

    // MARK: - setup / detect

    private var repoTemplates: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("launchd")
    }

    /// Sandbox paths for Set up: temp dirs only, no launchctl, no login item.
    private func sandboxPaths(nodeAvailable: Bool = true, inApplications: Bool = true) throws -> BackgroundRefreshService.Paths {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("hud cli setup \(UUID().uuidString)")
        addTeardownBlock { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let bundledBin = root.appendingPathComponent("Usage HUD.app/Contents/Resources/bin")
        try fm.createDirectory(at: bundledBin, withIntermediateDirectories: true)
        try "#!/bin/sh\necho v1\n".write(to: bundledBin.appendingPathComponent("codex-usage-refresh"), atomically: true, encoding: .utf8)
        let state = home.appendingPathComponent(".codex-usage-hud")
        try fm.createDirectory(at: state, withIntermediateDirectories: true)
        let app = inApplications ? "Applications" : "Downloads"
        return BackgroundRefreshService.Paths(
            supportDirectory: home.appendingPathComponent("Library/Application Support/Codex Usage HUD"),
            launchdDirectory: root.appendingPathComponent("LaunchAgents"),
            bundledBinDirectory: bundledBin,
            templateDirectory: repoTemplates,
            home: home,
            stateDirectory: state,
            appExecutable: home.appendingPathComponent("\(app)/Usage HUD.app/Contents/MacOS/CodexUsageHUD").path,
            invokeLaunchctl: false,
            nodeAvailable: nodeAvailable,
            pythonAvailable: true
        )
    }

    private func detection(claude: Bool = true, codex: Bool = true, grok: Bool = false, node: Bool = true) -> DetectionSummary {
        DetectionSummary(
            detectedAt: F.now,
            claude: claude ? .found("Claude Code credentials file") : .missing("Claude Code is not installed"),
            codex: codex ? .found("Codex session logs") : .missing("Codex is not installed"),
            gemini: .missing("Gemini is not installed"),
            grok: grok ? .found("Grok credentials") : .missing("Grok is not signed in"),
            local: .missing("Ollama is not installed"),
            node: node ? .found("Node.js") : .missing("Node.js is not installed"),
            python3: .found("Python 3")
        )
    }

    private func hooks(_ summary: DetectionSummary, paths: BackgroundRefreshService.Paths) -> AgentCLI.SetupHooks {
        AgentCLI.SetupHooks(
            detect: { summary },
            inspect: { AgentSetup.detectReport(summary: $0, launchdDirectory: paths.launchdDirectory,
                                               stateDirectory: paths.stateDirectory) },
            install: { AgentSetup.runSetup(summary: $0, paths: paths, waitTimeout: 0, recordDetection: { _ in }) }
        )
    }

    private func lanes(_ json: [String: Any]) throws -> [String: [String: Any]] {
        let lanes = try XCTUnwrap(json["lanes"] as? [[String: Any]])
        return Dictionary(uniqueKeysWithValues: lanes.map { ($0["id"] as! String, $0) })
    }

    func testDetectJSONReportsWithoutChangingAnything() throws {
        let paths = try sandboxPaths()
        let (code, c) = run(["detect", "--json"], setup: hooks(detection(grok: true), paths: paths))
        XCTAssertEqual(code, AgentCLI.ExitCode.ok)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(c.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(json["command"] as? String, "detect")
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["nothingFound"] as? Bool, false)
        XCTAssertEqual((json["lanes"] as? [[String: Any]])?.map { $0["id"] as? String }, ["claude", "codex", "gemini", "grok", "local"])
        let byId = try lanes(json)
        for lane in byId.values {
            for key in ["id", "displayName", "tool", "found", "detail", "installed", "job", "reading", "nextAction"] {
                XCTAssertNotNil(lane[key], "\(lane["id"] ?? "?") lacks \(key)")
            }
            XCTAssertEqual(lane["installed"] as? Bool, false, "detect must not install")
        }
        XCTAssertEqual(byId["grok"]?["found"] as? Bool, true)
        XCTAssertEqual(byId["gemini"]?["found"] as? Bool, false)
        XCTAssertTrue((byId["gemini"]?["nextAction"] as? String)?.contains("run setup again") == true)
        XCTAssertTrue(byId["claude"]?["nextAction"] is NSNull)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.launchdDirectory.path), "detect wrote a LaunchAgent")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.supportDirectory.path), "detect copied helpers")

        let (none, n) = run(["detect"], setup: hooks(detection(claude: false, codex: false), paths: paths))
        XCTAssertEqual(none, AgentCLI.ExitCode.noReadings)
        XCTAssertTrue(n.stdout.hasPrefix("No supported tool was found on this Mac."))
    }

    func testSetupJSONInstallsJobsForFoundLanesAndNamesNextActions() throws {
        let paths = try sandboxPaths()
        try """
        {"schemaVersion":1,"provider":"claude","week":{"label":"weekly","usedPct":42},"contributors":[],"skills":[],"subagents":[]}
        """.write(to: paths.stateDirectory.appendingPathComponent("claude-usage.json"), atomically: true, encoding: .utf8)

        let (code, c) = run(["setup", "--json"], setup: hooks(detection(grok: true), paths: paths))
        XCTAssertEqual(code, AgentCLI.ExitCode.ok, c.stdout)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(c.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(json["command"] as? String, "setup")
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertTrue((json["message"] as? String)?.hasPrefix("Set up complete.") == true)
        let byId = try lanes(json)

        XCTAssertEqual(byId["claude"]?["installed"] as? Bool, true)
        XCTAssertEqual(byId["claude"]?["reading"] as? String, "42% of the week used")
        XCTAssertTrue(byId["claude"]?["nextAction"] is NSNull)
        XCTAssertEqual(byId["grok"]?["installed"] as? Bool, true)
        XCTAssertTrue((byId["grok"]?["job"] as? String)?.hasPrefix("plist written") == true)
        XCTAssertEqual(byId["grok"]?["nextAction"] as? String, "Sign in to Grok, then run setup again.")
        XCTAssertEqual(byId["codex"]?["nextAction"] as? String, "Run one Codex session, then run setup again.")
        XCTAssertEqual(byId["gemini"]?["found"] as? Bool, false)
        XCTAssertEqual(byId["gemini"]?["installed"] as? Bool, false)
        XCTAssertEqual(byId["local"]?["nextAction"] as? String, "Install and start Ollama, then run setup again.")

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: paths.launchdDirectory.appendingPathComponent("com.codexusagehud.grok-writer.plist").path))
        XCTAssertTrue(fm.fileExists(atPath: paths.launchdDirectory.appendingPathComponent("com.codexusagehud.claude-writer.plist").path))
        // No macOS login item in the sandbox, so Set up fell back to the login
        // plist; the report says the app takes over on its next launch.
        XCTAssertTrue(fm.fileExists(atPath: paths.launchdDirectory.appendingPathComponent("com.codexusagehud.app.plist").path))
        XCTAssertTrue((json["notes"] as? [String])?.contains { $0.contains("Open at login") } == true)
        XCTAssertTrue(fm.fileExists(atPath: paths.supportDirectory.appendingPathComponent("bin/codex-usage-refresh").path))

        // Text form: one line per lane, next actions included.
        let (textCode, t) = run(["setup"], setup: hooks(detection(grok: true), paths: paths))
        XCTAssertEqual(textCode, AgentCLI.ExitCode.ok)
        let lines = t.stdout.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasPrefix("Set up complete."))
        XCTAssertTrue(lines.contains { $0.hasPrefix("Grok") && $0.contains("next: Sign in to Grok, then run setup again.") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("Claude") && $0.contains("reading: 42% of the week used") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("Note: Open at login") })
    }

    func testSetupWithoutNodeSaysWhichLanesNeedItAndStillExits0ForInAppLanes() throws {
        let paths = try sandboxPaths(nodeAvailable: false)
        let (code, c) = run(["setup", "--json"], setup: hooks(detection(grok: true, node: false), paths: paths))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(c.stdout.utf8)) as? [String: Any])
        let byId = try lanes(json)
        XCTAssertEqual(byId["grok"]?["installed"] as? Bool, false)
        XCTAssertEqual(byId["grok"]?["job"] as? String, "skipped (needs Node.js)")
        XCTAssertTrue((byId["grok"]?["nextAction"] as? String)?.contains("Node.js") == true)
        XCTAssertTrue((byId["claude"]?["job"] as? String)?.contains("read in the app") == true)
        XCTAssertTrue((json["notes"] as? [String])?.contains { $0.contains("Node.js") } == true, c.stdout)
        // No reading and no job: exit 1, not 3 (tools were found).
        XCTAssertEqual(code, AgentCLI.ExitCode.noRoom)
        XCTAssertEqual(json["nothingFound"] as? Bool, false)
    }

    func testSetupFromDownloadsReportsTheBlockerAndInstallsNothing() throws {
        let paths = try sandboxPaths(inApplications: false)
        let (code, c) = run(["setup", "--json"], setup: hooks(detection(), paths: paths))
        XCTAssertEqual(code, AgentCLI.ExitCode.noRoom)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(c.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(json["ok"] as? Bool, false)
        XCTAssertTrue((json["blocker"] as? String)?.contains("Move Usage HUD to Applications") == true)
        XCTAssertTrue((json["message"] as? String)?.hasPrefix("Set up did not run.") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.launchdDirectory.path))

        let (none, n) = run(["setup", "--json"], setup: hooks(detection(claude: false, codex: false), paths: paths))
        XCTAssertEqual(none, AgentCLI.ExitCode.noReadings)
        let noneJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(n.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(noneJSON["nothingFound"] as? Bool, true)
        XCTAssertTrue((noneJSON["message"] as? String)?.contains("Nothing was installed") == true)
        XCTAssertEqual(run(["setup", "extra"]).0, AgentCLI.ExitCode.usage)
    }

    func testGUILaunchArgumentsFallThroughToTheApp() {
        XCTAssertNil(AgentCLI.runIfRequested(arguments: ["/x/CodexUsageHUD"]))
        XCTAssertNil(AgentCLI.runIfRequested(arguments: ["/x/CodexUsageHUD", "-psn_0_12345"]))
        XCTAssertNil(AgentCLI.runIfRequested(arguments: ["/x/CodexUsageHUD", "-NSDocumentRevisionsDebugMode", "YES"]))
    }

    func testStatusPrintsVerdictRoomAndOneLinePerLane() {
        let (code, c) = run(["status"])
        XCTAssertEqual(code, AgentCLI.ExitCode.ok)
        let lines = c.out.joined(separator: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines[0], "GO  Claude: clear to build.")
        XCTAssertEqual(lines[1], "Room now: Grok, 8% of its week used, on pace, resets in 6d.")
        XCTAssertTrue(lines.contains { $0.hasPrefix("Codex") && $0.contains("93%") && $0.contains("almost spent") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("Claude") && $0.contains("measured, 1m old") })
    }

    func testStatusJSONIsTheSchema() throws {
        let (code, c) = run(["status", "--json"])
        XCTAssertEqual(code, 0)
        let json = try JSONSerialization.jsonObject(with: Data(c.stdout.utf8))
        XCTAssertEqual(MiniSchemaValidator.errors(json, schema: AgentSchema.summary), [])
    }

    func testRoomExitCodes() {
        let (ok, okOut) = run(["room"])
        XCTAssertEqual(ok, AgentCLI.ExitCode.ok)
        XCTAssertEqual(okOut.stdout, "Grok has the most room now: 8% of its week used, on pace, resets in 6d.")

        let (none, noneOut) = run(["room"], snapshots: [F.snapshot("claude", week: 95)])
        XCTAssertEqual(none, AgentCLI.ExitCode.noRoom)
        XCTAssertTrue(noneOut.stdout.hasPrefix("No plan clearly has room right now."))

        let (empty, _) = run(["room"], snapshots: [])
        XCTAssertEqual(empty, AgentCLI.ExitCode.noReadings)
        let (emptyStatus, _) = run(["status"], snapshots: [])
        XCTAssertEqual(emptyStatus, AgentCLI.ExitCode.noReadings)

        let (jsonCode, jsonOut) = run(["room", "--json"])
        XCTAssertEqual(jsonCode, 0)
        let json = try? JSONSerialization.jsonObject(with: Data(jsonOut.stdout.utf8))
        XCTAssertEqual(json.map { MiniSchemaValidator.errors($0, schema: AgentSchema.roomAdvice) }, [])
    }

    func testLaneLookup() {
        let (code, c) = run(["lane", "Claude Code"])
        XCTAssertEqual(code, 0)
        XCTAssertTrue(c.stdout.contains("5h: 12% used"))
        XCTAssertTrue(c.stdout.contains("week (Fable): 5% used"))

        let (unknown, u) = run(["lane", "nope"])
        XCTAssertEqual(unknown, AgentCLI.ExitCode.usage)
        XCTAssertTrue(u.err.joined().contains("unknown provider"))

        let (hidden, h) = run(["lane", "grok"], snapshots: [F.snapshot("claude", week: 10)])
        XCTAssertEqual(hidden, AgentCLI.ExitCode.usage)
        XCTAssertTrue(h.err.joined().contains("not tracked"))

        XCTAssertEqual(run(["lane"]).0, AgentCLI.ExitCode.usage)
    }

    func testUsageErrors() {
        let (bad, c) = run(["stauts"])
        XCTAssertEqual(bad, AgentCLI.ExitCode.usage)
        XCTAssertTrue(c.err.joined().contains("unknown command 'stauts'"))
        XCTAssertTrue(c.out.isEmpty, "errors go to stderr only")
        XCTAssertEqual(run(["status", "--bogus"]).0, AgentCLI.ExitCode.usage)
        XCTAssertEqual(run(["status", "extra"]).0, AgentCLI.ExitCode.usage)
        XCTAssertEqual(run(["mcp", "--json"]).0, AgentCLI.ExitCode.usage)
    }

    func testHelpVersionPromptSchemaAndMCP() throws {
        let (helpCode, help) = run(["help"])
        XCTAssertEqual(helpCode, 0)
        XCTAssertTrue(help.stdout.contains("Exit codes:"))
        XCTAssertTrue(help.stdout.contains("setup [--json]"))
        XCTAssertTrue(help.stdout.contains("detect [--json]"))
        XCTAssertTrue(help.stdout.contains("'/Applications/Usage HUD.app/Contents/MacOS/CodexUsageHUD' <command>"))
        XCTAssertEqual(run(["--help"]).1.stdout, help.stdout)
        XCTAssertEqual(run(["status", "--help"]).1.stdout, help.stdout)

        let (versionCode, version) = run(["--version"])
        XCTAssertEqual(versionCode, 0)
        XCTAssertTrue(version.stdout.hasPrefix("Usage HUD "))
        XCTAssertTrue(version.stdout.contains("2026-07-28"))

        let (promptCode, prompt) = run(["prompt"])
        XCTAssertEqual(promptCode, 0)
        XCTAssertTrue(prompt.stdout.contains("claude mcp add --scope user usage-hud -- '/Applications/Usage HUD.app/Contents/MacOS/CodexUsageHUD' mcp"))

        let (schemaCode, schema) = run(["schema"])
        XCTAssertEqual(schemaCode, 0)
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(schema.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["title"] as? String, "UsageHUDAgentSummary")

        var served = false
        let (mcpCode, _) = run(["mcp"], mcp: { served = true; return 0 })
        XCTAssertEqual(mcpCode, 0)
        XCTAssertTrue(served)
    }
}

final class AgentPromptTests: XCTestCase {
    private let path = "/Applications/Usage HUD.app/Contents/MacOS/CodexUsageHUD"
    private var text: String { AgentPrompt.text(executablePath: path, home: "/Users/pat") }

    func testShellQuoting() {
        XCTAssertEqual(AgentPrompt.shellQuote("/usr/local/bin/usage-hud"), "/usr/local/bin/usage-hud")
        XCTAssertEqual(AgentPrompt.shellQuote("/A B/x"), "'/A B/x'")
        XCTAssertEqual(AgentPrompt.shellQuote("Bob's"), "'Bob'\\''s'")
        XCTAssertEqual(AgentPrompt.shellQuote(""), "''")
    }

    /// The quoted word must come back out of a real shell byte-for-byte.
    func testShellQuotedPathSurvivesTheShell() throws {
        for raw in [path, "/tmp/Bob's Apps/Usage HUD.app/x", "/tmp/$HOME `id` \"q\"/x", "/tmp/tab\there"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf %s " + AgentPrompt.shellQuote(raw)]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(out, raw)
        }
    }

    func testTOMLAndJSONStrings() throws {
        XCTAssertEqual(AgentPrompt.tomlString(#"/a "b"\c"#), #""/a \"b\"\\c""#)
        let json = AgentPrompt.jsonString(#"/a "b"\c/d"#)
        let decoded = try JSONSerialization.jsonObject(with: Data("[\(json)]".utf8)) as? [String]
        XCTAssertEqual(decoded, [#"/a "b"\c/d"#])
    }

    func testPromptCarriesExactCommandsForEachAgent() {
        let quoted = "'\(path)'"
        XCTAssertTrue(text.contains("\(quoted) status"))
        XCTAssertTrue(text.contains("claude mcp add --scope user usage-hud -- \(quoted) mcp"))
        XCTAssertTrue(text.contains("codex mcp add usage-hud -- \(quoted) mcp"))
        XCTAssertTrue(text.contains("gemini mcp add --scope user usage-hud \(quoted) mcp"))
        XCTAssertTrue(text.contains("[mcp_servers.usage-hud]\n     command = \"\(path)\"\n     args = [\"mcp\"]"))
        XCTAssertTrue(text.contains("\"usage-hud\": { \"command\": \"\(path)\", \"args\": [\"mcp\"] }"))
        XCTAssertTrue(text.contains("/Users/pat/.codex/config.toml"))
        XCTAssertTrue(text.contains("/Users/pat/.gemini/settings.json"))
        XCTAssertTrue(text.contains("/Users/pat/.claude/CLAUDE.md"))
        XCTAssertTrue(text.contains("/Users/pat/.codex/AGENTS.md"))
        XCTAssertTrue(text.contains("/Users/pat/.gemini/GEMINI.md"))
    }

    func testPromptIsHonest() {
        // Skips what is missing, never duplicates, asks before editing
        // instruction files, and shows every change.
        XCTAssertTrue(text.contains("skip any that are missing"))
        XCTAssertTrue(text.contains("already has a server named usage-hud, leave it alone"))
        XCTAssertTrue(text.contains("Only if I say yes"))
        XCTAssertTrue(text.contains("Show me every change you made"))
        // No readings yet: the agent runs setup itself instead of stopping.
        XCTAssertTrue(text.contains("If it says there are no readings yet, run:\n   '\(path)' setup"))
        XCTAssertTrue(text.contains("It needs no keys or logins."))
        XCTAssertFalse(text.contains("and stop."))
        XCTAssertTrue(text.contains("Before long or parallel work, check Usage HUD"))
        XCTAssertTrue(text.contains("If your plan is running hot or nearly out, tell the user and name the plan that has room."))
        XCTAssertTrue(text.contains("To undo later"))
        // No links, no selling, no secrets.
        for banned in ["http", "tip", "review", "github", "share", "token", "password", "api key"] {
            XCTAssertFalse(text.lowercased().contains(banned), "prompt mentions \(banned)")
        }
    }
}
