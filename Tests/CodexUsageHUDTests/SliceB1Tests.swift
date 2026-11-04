import XCTest
import Security
@testable import CodexUsageHUD

final class SliceB1Tests: XCTestCase {
    private func tempDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hud-b1-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func defaultsSuite() throws -> UserDefaults {
        let name = "UsageHUDTests.b1.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
        }
        return defaults
    }

    // MARK: - Tool detection

    func testKeychainQueryRequestsAttributesNeverData() {
        let query = ToolDetection.keychainAttributeQuery()
        XCTAssertEqual(query[kSecAttrService as String] as? String, "Claude Code-credentials")
        XCTAssertEqual(query[kSecReturnAttributes as String] as? Bool, true)
        XCTAssertNil(query[kSecReturnData as String])
        XCTAssertNotEqual(query[kSecReturnData as String] as? Bool, true)
    }

    func testSimulatedFirstLaunchFindsClaudeAndCodexOnly() throws {
        let home = try tempDir("home")
        let claudeDir = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try Data().write(to: claudeDir.appendingPathComponent(".credentials.json"))
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".codex/sessions"),
            withIntermediateDirectories: true
        )

        let fm = FileManager.default
        var keychainAskedFor: [String] = []
        let probe = ToolDetection.Probe(
            home: home,
            fileExists: { url in
                url.path.hasPrefix(home.path) && fm.fileExists(atPath: url.path)
            },
            isExecutable: { url in
                url.path.hasPrefix(home.path) && fm.isExecutableFile(atPath: url.path)
            },
            keychainItemExists: { service in
                keychainAskedFor.append(service)
                return false
            },
            nodeAvailable: true,
            python3Available: true
        )
        let summary = ToolDetection.detect(probe: probe)

        XCTAssertTrue(summary.claude.isFound, summary.claude.reason)
        XCTAssertTrue(summary.codex.isFound, summary.codex.reason)
        XCTAssertFalse(summary.gemini.isFound)
        XCTAssertFalse(summary.grok.isFound)
        XCTAssertFalse(summary.local.isFound)
        XCTAssertEqual(summary.foundDisplayNames, ["Claude Code", "Codex"])
        XCTAssertEqual(summary.missingDisplayNames, ["Gemini", "Grok", "Ollama"])
        XCTAssertEqual(summary.foundLine, "Found: Claude Code, Codex")
        XCTAssertEqual(summary.missingLine, "Not found: Gemini, Grok, Ollama")
        XCTAssertEqual(keychainAskedFor, ["Claude Code-credentials"])
    }

    func testClaudeFoundViaKeychainWithoutCredentialsFile() {
        let home = URL(fileURLWithPath: "/tmp/hud-b1-claude-keychain")
        let probe = ToolDetection.Probe(
            home: home,
            fileExists: { $0.path.hasSuffix("/.claude") },
            isExecutable: { _ in false },
            keychainItemExists: { $0 == "Claude Code-credentials" },
            nodeAvailable: true,
            python3Available: true
        )
        XCTAssertTrue(ToolDetection.detect(probe: probe).claude.isFound)
    }

    func testClaudeMissingWhenDirectoryHasNoCredentials() {
        let home = URL(fileURLWithPath: "/tmp/hud-b1-claude-unsigned")
        let probe = ToolDetection.Probe(
            home: home,
            fileExists: { $0.path.hasSuffix("/.claude") },
            isExecutable: { _ in false },
            keychainItemExists: { _ in false },
            nodeAvailable: true,
            python3Available: true
        )
        XCTAssertFalse(ToolDetection.detect(probe: probe).claude.isFound)
    }

    func testCodexFoundViaExecutableOnFixedPath() throws {
        let home = try tempDir("codex-bin")
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let exe = bin.appendingPathComponent("codex")
        try "#!/bin/sh\nexit 0\n".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        let summary = ToolDetection.detect(probe: .fileSystem(home: home))
        XCTAssertTrue(summary.codex.isFound, summary.codex.reason)
        XCTAssertFalse(summary.claude.isFound)
    }

    func testGeminiFoundOnlyViaAgy() {
        let home = URL(fileURLWithPath: "/tmp/hud-b1-gemini")
        let viaDir = ToolDetection.Probe(
            home: home,
            fileExists: { $0.path.hasSuffix("/.gemini") },
            isExecutable: { _ in false },
            keychainItemExists: { _ in false },
            nodeAvailable: true,
            python3Available: true
        )
        // A Gemini config alone has no quota source the app can read.
        XCTAssertFalse(ToolDetection.detect(probe: viaDir).gemini.isFound)

        let viaAgy = ToolDetection.Probe(
            home: home,
            fileExists: { _ in false },
            isExecutable: { $0.lastPathComponent == "agy" },
            keychainItemExists: { _ in false },
            nodeAvailable: true,
            python3Available: true
        )
        XCTAssertTrue(ToolDetection.detect(probe: viaAgy).gemini.isFound)
    }

    func testGrokRequiresAuthFile() {
        let home = URL(fileURLWithPath: "/tmp/hud-b1-grok")
        let missing = ToolDetection.Probe(
            home: home,
            fileExists: { _ in false },
            isExecutable: { _ in false },
            keychainItemExists: { _ in false },
            nodeAvailable: true,
            python3Available: true
        )
        XCTAssertFalse(ToolDetection.detect(probe: missing).grok.isFound)

        let found = ToolDetection.Probe(
            home: home,
            fileExists: { $0.path.hasSuffix("/.grok/auth.json") },
            isExecutable: { _ in false },
            keychainItemExists: { _ in false },
            nodeAvailable: true,
            python3Available: true
        )
        XCTAssertTrue(ToolDetection.detect(probe: found).grok.isFound)
    }

    func testLocalModelsFoundViaOllamaAppWithoutNetwork() {
        let home = URL(fileURLWithPath: "/tmp/hud-b1-ollama")
        let probe = ToolDetection.Probe(
            home: home,
            fileExists: { $0.path == "/Applications/Ollama.app" },
            isExecutable: { _ in false },
            keychainItemExists: { _ in false },
            nodeAvailable: true,
            python3Available: true
        )
        XCTAssertTrue(ToolDetection.detect(probe: probe).local.isFound)
        XCTAssertEqual(ToolDetection.detect(probe: probe).local.reason, "Ollama app")
    }

    func testRuntimeNoteWhenNodeOrPythonMissing() {
        // Claude and Codex are read in-app; no lane needs Python any more.
        XCTAssertNil(DetectionSummary.runtimeNote(nodeAvailable: true, pythonAvailable: true))
        XCTAssertNil(DetectionSummary.runtimeNote(nodeAvailable: true, pythonAvailable: false))
        XCTAssertEqual(
            DetectionSummary.runtimeNote(nodeAvailable: false, pythonAvailable: true),
            "Gemini and Grok need Node.js. \(RuntimeDependencies.nodeInstallHint)."
        )
        XCTAssertEqual(
            DetectionSummary.runtimeNote(nodeAvailable: false, pythonAvailable: false),
            "Gemini and Grok need Node.js. \(RuntimeDependencies.nodeInstallHint)."
        )
    }

    // MARK: - First-launch preferences

    func testFirstLaunchShowsFoundHidesMissing() throws {
        let defaults = try defaultsSuite()
        let fileURL = try tempDir("prefs").appendingPathComponent("provider-preferences.json")
        let summary = ToolDetection.detect(
            probe: ToolDetection.Probe(
                home: URL(fileURLWithPath: "/tmp/hud-b1-prefs"),
                fileExists: {
                    $0.path.hasSuffix("/.claude")
                        || $0.path.hasSuffix("/.credentials.json")
                        || $0.path.hasSuffix("/sessions")
                },
                isExecutable: { _ in false },
                keychainItemExists: { _ in false },
                    nodeAvailable: true,
                python3Available: true
            )
        )

        let applied = ProviderPreferences.ensureInitialized(
            defaults: defaults,
            fileURL: fileURL,
            isolated: false,
            detect: { summary }
        )
        XCTAssertNotNil(applied)
        XCTAssertTrue(ProviderPreferences.isConnected("claude", defaults: defaults))
        XCTAssertTrue(ProviderPreferences.isShown("claude", defaults: defaults))
        XCTAssertTrue(ProviderPreferences.isShown("codex", defaults: defaults))
        XCTAssertFalse(ProviderPreferences.isConnected("gemini", defaults: defaults))
        XCTAssertFalse(ProviderPreferences.isShown("gemini", defaults: defaults))
        XCTAssertFalse(ProviderPreferences.isShown("grok", defaults: defaults))
        XCTAssertFalse(ProviderPreferences.isShown("local", defaults: defaults))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(ProviderPreferences.storedFile(fileURL)?.found, ["Claude Code", "Codex"])
    }

    func testExistingPreferencesFileIsLeftUntouched() throws {
        let defaults = try defaultsSuite()
        let fileURL = try tempDir("existing").appendingPathComponent("provider-preferences.json")
        defaults.set(true, forKey: ProviderPreferences.connectedKey(for: "gemini"))
        defaults.set(true, forKey: ProviderPreferences.shownKey(for: "gemini"))
        let original = ProviderPreferencesFile(
            detectedAt: "2026-01-01T00:00:00.000Z",
            found: ["Gemini"],
            missing: ["Claude Code", "Codex", "Grok", "Ollama"],
            connected: ["gemini"],
            shown: ["gemini"],
            setupCompleteAcknowledged: false,
            nodeAvailable: true,
            pythonAvailable: true,
            runtimeNote: nil
        )
        let data = try JSONEncoder().encode(original)
        try data.write(to: fileURL)

        var detectCalls = 0
        ProviderPreferences.ensureInitialized(
            defaults: defaults,
            fileURL: fileURL,
            isolated: false,
            detect: {
                detectCalls += 1
                return ToolDetection.detect(probe: .fileSystem(home: URL(fileURLWithPath: "/tmp/unused")))
            }
        )
        XCTAssertEqual(detectCalls, 0)
        let stored = try XCTUnwrap(ProviderPreferences.storedFile(fileURL))
        XCTAssertEqual(stored.found, ["Gemini"])
        XCTAssertEqual(stored.connected, ["gemini"])
        XCTAssertTrue(ProviderPreferences.isShown("gemini", defaults: defaults))
    }

    func testDetectAgainReappliesAndMayHideLanes() throws {
        let defaults = try defaultsSuite()
        let fileURL = try tempDir("redetect").appendingPathComponent("provider-preferences.json")
        defaults.set(true, forKey: ProviderPreferences.connectedKey(for: "gemini"))
        defaults.set(true, forKey: ProviderPreferences.shownKey(for: "gemini"))

        let empty = ToolDetection.detect(probe: .fileSystem(home: URL(fileURLWithPath: "/tmp/hud-b1-empty")))
        _ = ProviderPreferences.detectAgain(defaults: defaults, fileURL: fileURL, detect: { empty })
        XCTAssertFalse(ProviderPreferences.isShown("gemini", defaults: defaults))
        XCTAssertEqual(ProviderPreferences.detectAgainHelp.contains("Turns lanes on or off"), true)
    }

    // MARK: - Setup card

    // A home that never exists. A fixed path like /tmp/x picks up whatever
    // another process left there: a stray file makes Grok's session scan
    // uncertain, which correctly reports Grok as found.
    private static let missingHome = FileManager.default.temporaryDirectory
        .appendingPathComponent("hud-missing-home-\(UUID().uuidString)", isDirectory: true)

    func testSetupCardPromptNotInstalled() {
        let summary = ToolDetection.detect(
            probe: ToolDetection.Probe(
                home: Self.missingHome,
                fileExists: { $0.path.hasSuffix("/.claude") || $0.path.hasSuffix("/.credentials.json") || $0.path.hasSuffix("/sessions") },
                isExecutable: { _ in false },
                keychainItemExists: { _ in false },
                    nodeAvailable: true,
                python3Available: true
            )
        )
        let card = SetupCardModel.live(installed: false, summary: summary, acknowledged: false)
        XCTAssertEqual(card.phase, .prompt)
        XCTAssertEqual(card.foundLine, "Found: Claude Code, Codex")
        XCTAssertEqual(card.missingLine, "Not found: Gemini, Grok, Ollama")
        XCTAssertEqual(card.buttonTitle, "Set up")
        XCTAssertTrue(card.buttonSubtext.contains("About 10 seconds"))
        XCTAssertNil(card.runtimeNote)
    }

    func testSetupCardHiddenWhenInstalledOrAcknowledged() {
        let summary = ToolDetection.detect(probe: .fileSystem(home: Self.missingHome))
        XCTAssertEqual(SetupCardModel.live(installed: true, summary: summary, acknowledged: false).phase, .hidden)
        XCTAssertEqual(SetupCardModel.live(installed: false, summary: summary, acknowledged: true).phase, .hidden)
    }

    func testSetupCardRunningAndDoneStates() {
        let summary = ToolDetection.detect(probe: .fileSystem(home: Self.missingHome, nodeAvailable: false))
        let running = SetupCardModel.running(summary: summary)
        XCTAssertEqual(running.phase, .running)
        XCTAssertEqual(running.runtimeNote, "Gemini and Grok need Node.js. \(RuntimeDependencies.nodeInstallHint).")

        let lanes = [
            LaneSetupResult(provider: "claude", name: "Claude", status: .success("Claude ✓ 42% of the week used")),
            LaneSetupResult(provider: "gemini", name: "Gemini", status: .failure("Gemini ✗ not signed in")),
        ]
        let done = SetupCardModel.finished(summary: summary, lanes: lanes, hasData: true)
        XCTAssertEqual(done.phase, .doneWithData)
        XCTAssertEqual(done.completeLine, "Set up complete")

        let empty = SetupCardModel.finished(summary: summary, lanes: lanes.filter { !$0.status.isSuccess }, hasData: false)
        XCTAssertEqual(empty.phase, .doneWithNoData)
    }

    func testSetupCardFixturePromptAndComplete() throws {
        let dir = try tempDir("fixture")
        let prompt = """
        {"phase":"prompt","found":["Claude Code","Codex"],"missing":["Gemini","Grok","Ollama"]}
        """
        try prompt.write(to: dir.appendingPathComponent("setup-card.json"), atomically: true, encoding: .utf8)
        let card = try XCTUnwrap(SetupCardModel.loadFixture(from: dir))
        XCTAssertEqual(card.phase, .prompt)
        XCTAssertEqual(card.foundLine, "Found: Claude Code, Codex")

        let done = """
        {"phase":"complete"}
        """
        try done.write(to: dir.appendingPathComponent("setup-card.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SetupCardModel.loadFixture(from: dir)?.phase, .doneWithData)
    }

    func testLaneScoringFormatsWeekPercentAndFailures() throws {
        let dir = try tempDir("score")
        let json = """
        {"schemaVersion":1,"provider":"claude","week":{"label":"weekly","usedPct":42},"contributors":[],"skills":[],"subagents":[]}
        """
        try json.write(to: dir.appendingPathComponent("claude-usage.json"), atomically: true, encoding: .utf8)
        let claude = LaneSetupScoring.result(
            provider: "claude",
            snapshot: LaneSetupScoring.loadSnapshot(provider: "claude", stateDirectory: dir),
            nodeAvailable: true,
            pythonAvailable: true
        )
        XCTAssertEqual(claude.line, "Claude ✓ 42% of the week used")
        XCTAssertEqual(
            LaneSetupScoring.result(provider: "codex", snapshot: nil, nodeAvailable: true, pythonAvailable: true).line,
            "Codex ✗ no session yet"
        )
        XCTAssertEqual(
            LaneSetupScoring.result(provider: "gemini", snapshot: nil, nodeAvailable: true, pythonAvailable: true).line,
            "Gemini ✗ not signed in"
        )
        // No runtime is required for Claude: the in-app reader covers it.
        XCTAssertEqual(
            LaneSetupScoring.result(provider: "claude", snapshot: nil, nodeAvailable: false, pythonAvailable: false).line,
            "Claude ✗ not signed in"
        )
    }

    func testSetupRequiresUsableReadingAndNamesItsWindow() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stamp = ISO8601DateFormatter().string(from: now)
        func score(_ snapshot: UsageSnapshot) -> LaneSetupResult {
            LaneSetupScoring.result(provider: snapshot.provider, snapshot: snapshot,
                                    nodeAvailable: true, pythonAvailable: true, now: now)
        }
        let empty = score(UsageSnapshot(provider: "codex", capturedAt: stamp))
        XCTAssertFalse(empty.status.isSuccess)
        XCTAssertFalse(LaneSetupScoring.hasUsableData([empty]))
        XCTAssertTrue(empty.line.contains("no usage reading yet"))

        let session = UsageSnapshot(provider: "codex", capturedAt: stamp,
                                    currentSession: .init(usedPct: 0))
        XCTAssertEqual(score(session).line, "Codex ✓ 0% of the session used")
        var stale = session
        stale.capturedAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(-48 * 3600))
        XCTAssertFalse(score(stale).status.isSuccess)
        var oldWindow = session
        oldWindow.currentSession?.eventAt = stale.capturedAt
        XCTAssertFalse(score(oldWindow).status.isSuccess)
        var degraded = session
        degraded.health = .init(verdict: "degraded", reason: "fetch failed")
        XCTAssertFalse(score(degraded).status.isSuccess)
        var expired = session
        expired.currentSession?.resetAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(-1))
        XCTAssertFalse(score(expired).status.isSuccess)
        var unknown = session
        unknown.currentSession = .init(usedPct: 20, state: "unknown")
        XCTAssertFalse(score(unknown).status.isSuccess)
        var invalid = session
        invalid.currentSession?.usedPct = .infinity
        XCTAssertFalse(score(invalid).status.isSuccess)

        let local = try JSONDecoder().decode(UsageSnapshot.self, from: Data(
            "{\"provider\":\"local\",\"capturedAt\":\"\(stamp)\",\"session\":{\"total\":0}}".utf8))
        XCTAssertTrue(score(local).status.isSuccess)
        var cloud = local
        cloud.provider = "codex"
        XCTAssertFalse(score(cloud).status.isSuccess)
    }

    func testSetupCardStatesCarryTrustLine() throws {
        let expected = "Readings stay on this Mac. Every number shows where it came from — official, measured, estimated or unknown."
        let summary = ToolDetection.detect(probe: .fileSystem(home: URL(fileURLWithPath: "/tmp/hud-b1-trust")))

        let prompt = SetupCardModel.prompt(summary: summary)
        XCTAssertEqual(prompt.trustLine, expected)
        XCTAssertFalse(prompt.trustLine.isEmpty)

        let running = SetupCardModel.running(summary: summary)
        XCTAssertEqual(running.trustLine, expected)
        XCTAssertFalse(running.trustLine.isEmpty)

        let doneWithData = SetupCardModel.finished(summary: summary, lanes: [], hasData: true)
        XCTAssertEqual(doneWithData.trustLine, expected)
        XCTAssertFalse(doneWithData.trustLine.isEmpty)

        let doneWithNoData = SetupCardModel.finished(summary: summary, lanes: [], hasData: false)
        XCTAssertEqual(doneWithNoData.trustLine, expected)
        XCTAssertFalse(doneWithNoData.trustLine.isEmpty)
    }

    func testSetupCardTrustLineMentionsLocalAndConfidence() {
        let trustLine = SetupCardModel.hidden.trustLine
        XCTAssertTrue(trustLine.contains("stay on this Mac"))
        XCTAssertTrue(trustLine.contains("official"))
    }

    func testLaneScoringAppendsDeclaredConfidence() {
        let official = UsageSnapshot(
            provider: "claude",
            confidence: "official",
            week: UsageSnapshot.WindowMetric(label: "weekly", usedPct: 42)
        )
        XCTAssertEqual(
            LaneSetupScoring.result(provider: "claude", snapshot: official, nodeAvailable: true, pythonAvailable: true).line,
            "Claude ✓ 42% of the week used · official"
        )

        let high = UsageSnapshot(
            provider: "codex",
            confidence: "high",
            week: UsageSnapshot.WindowMetric(label: "weekly", usedPct: 12)
        )
        XCTAssertEqual(
            LaneSetupScoring.result(provider: "codex", snapshot: high, nodeAvailable: true, pythonAvailable: true).line,
            "Codex ✓ 12% of the week used · high"
        )
    }

    func testLaneScoringOmitsConfidenceWhenNotDeclared() {
        let undeclared = UsageSnapshot(
            provider: "claude",
            confidence: nil,
            week: UsageSnapshot.WindowMetric(label: "weekly", usedPct: 42)
        )
        XCTAssertEqual(
            LaneSetupScoring.result(provider: "claude", snapshot: undeclared, nodeAvailable: true, pythonAvailable: true).line,
            "Claude ✓ 42% of the week used"
        )
    }

    func testLaneScoringDoesNotAdvertiseInferredConfidence() {
        let inferredOnly = UsageSnapshot(
            provider: "claude",
            sourceKind: "official_api",
            confidence: nil,
            week: UsageSnapshot.WindowMetric(label: "weekly", usedPct: 42)
        )
        XCTAssertEqual(
            LaneSetupScoring.result(provider: "claude", snapshot: inferredOnly, nodeAvailable: true, pythonAvailable: true).line,
            "Claude ✓ 42% of the week used"
        )
    }

    func testIsInstalledLooksForLaunchdPlists() throws {
        let root = try tempDir("launchd")
        let launchd = root.appendingPathComponent("LaunchAgents")
        try FileManager.default.createDirectory(at: launchd, withIntermediateDirectories: true)
        let paths = BackgroundRefreshService.Paths(
            supportDirectory: root.appendingPathComponent("support"),
            launchdDirectory: launchd,
            bundledBinDirectory: nil,
            templateDirectory: nil,
            home: root,
            stateDirectory: root.appendingPathComponent("state"),
            appExecutable: "/tmp/app",
            invokeLaunchctl: false,
            nodeAvailable: true,
            pythonAvailable: true
        )
        XCTAssertFalse(BackgroundRefreshService.isInstalled(paths: paths))
        try Data().write(to: launchd.appendingPathComponent("com.codexusagehud.refresh.plist"))
        XCTAssertTrue(BackgroundRefreshService.isInstalled(paths: paths))
    }

    func testSetUpAndRefreshScoresExistingFilesWithoutLaunchctl() throws {
        let fm = FileManager.default
        let root = try tempDir("setup-refresh")
        let bundledBin = root.appendingPathComponent("bundled-bin")
        let templates = root.appendingPathComponent("templates")
        let support = root.appendingPathComponent("support")
        let launchd = root.appendingPathComponent("launchd")
        let state = root.appendingPathComponent("state")
        try fm.createDirectory(at: bundledBin, withIntermediateDirectories: true)
        try fm.createDirectory(at: templates, withIntermediateDirectories: true)
        try fm.createDirectory(at: state, withIntermediateDirectories: true)
        try "#!/bin/sh\necho ok\n".write(
            to: bundledBin.appendingPathComponent("codex-usage-refresh"),
            atomically: true,
            encoding: .utf8
        )
        try fm.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: bundledBin.appendingPathComponent("codex-usage-refresh").path
        )
        let template = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>Label</key><string>LABEL</string>
        <key>Bin</key><string>%%BIN_DIR%%</string>
        </dict></plist>
        """
        for label in BundledHelpers.coreLaunchdLabels {
            try template.replacingOccurrences(of: "LABEL", with: label)
                .write(to: templates.appendingPathComponent("\(label).plist"), atomically: true, encoding: .utf8)
        }
        try """
        {"schemaVersion":1,"provider":"claude","week":{"usedPct":42},"contributors":[],"skills":[],"subagents":[]}
        """.write(to: state.appendingPathComponent("claude-usage.json"), atomically: true, encoding: .utf8)

        let paths = BackgroundRefreshService.Paths(
            supportDirectory: support,
            launchdDirectory: launchd,
            bundledBinDirectory: bundledBin,
            templateDirectory: templates,
            home: root,
            stateDirectory: state,
            // Set up refuses any copy outside an Applications folder.
            appExecutable: root.appendingPathComponent("Applications/CodexUsageHUD.app/Contents/MacOS/CodexUsageHUD").path,
            invokeLaunchctl: false,
            nodeAvailable: true,
            pythonAvailable: true
        )
        let outcome = BackgroundRefreshService.setUpAndRefresh(
            paths: paths,
            providers: ["claude", "codex"],
            waitTimeout: 0
        )
        XCTAssertTrue(outcome.report.text.contains("kickstart skipped"), outcome.report.text)
        XCTAssertTrue(outcome.hasData)
        XCTAssertEqual(outcome.lanes.first { $0.provider == "claude" }?.line, "Claude ✓ 42% of the week used")
        XCTAssertEqual(outcome.lanes.first { $0.provider == "codex" }?.line, "Codex ✗ no session yet")
    }

    func testPanelCopyHasNoCliNames() {
        let usageView = try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/CodexUsageHUD/UsageView.swift"),
            encoding: .utf8
        )
        let optional = try? String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/CodexUsageHUD/EmptyLaneCopy.swift"),
            encoding: .utf8
        )
        XCTAssertFalse((usageView ?? "").contains("codex-usage-refresh"))
        XCTAssertFalse((usageView ?? "").contains("codex-usage-doctor"))
        XCTAssertFalse((optional ?? "").contains("codex-usage-refresh"))
        XCTAssertFalse((optional ?? "").contains("codex-usage-doctor"))
    }
}
