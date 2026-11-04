import XCTest
@testable import CodexUsageHUD

/// Set up truth, self-retiring jobs, helper refresh after an update, Open at
/// login and owner-lane gating. Nothing here runs launchctl or touches
/// ~/Library: every path is a temp dir and `invokeLaunchctl` is false.
final class LifecycleTests: XCTestCase {
    private let fm = FileManager.default

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var repoTemplates: URL { repoRoot.appendingPathComponent("launchd") }

    private static let renderedLabels = BundledHelpers.coreLaunchdLabels

    private func tempDir(_ name: String) throws -> URL {
        // A space in every temp root: "Application Support" and
        // "Usage HUD.app" must survive rendering and the shell.
        let url = fm.temporaryDirectory.appendingPathComponent("hud life \(name) \(UUID().uuidString)")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { [fm] in try? fm.removeItem(at: url) }
        return url
    }

    private struct Sandbox {
        var root: URL
        var home: URL
        var bundledBin: URL
        var support: URL
        var launchd: URL
        var paths: BackgroundRefreshService.Paths
    }

    private func sandbox(
        appExecutable: String? = nil,
        templates: URL? = nil,
        build: String = "7",
        nodeAvailable: Bool = true
    ) throws -> Sandbox {
        let root = try tempDir("sandbox")
        let home = root.appendingPathComponent("home")
        let bundledBin = root.appendingPathComponent("Usage HUD.app/Contents/Resources/bin")
        try fm.createDirectory(at: bundledBin, withIntermediateDirectories: true)
        try "#!/bin/sh\necho v1\n".write(to: bundledBin.appendingPathComponent("codex-usage-refresh"), atomically: true, encoding: .utf8)
        let support = home.appendingPathComponent("Library/Application Support/Codex Usage HUD")
        let launchd = root.appendingPathComponent("LaunchAgents")
        var paths = BackgroundRefreshService.Paths(
            supportDirectory: support,
            launchdDirectory: launchd,
            bundledBinDirectory: bundledBin,
            templateDirectory: templates ?? repoTemplates,
            home: home,
            stateDirectory: home.appendingPathComponent(".codex-usage-hud"),
            appExecutable: appExecutable
                ?? home.appendingPathComponent("Applications/Usage HUD.app/Contents/MacOS/CodexUsageHUD").path,
            invokeLaunchctl: false,
            nodeAvailable: nodeAvailable,
            pythonAvailable: true
        )
        paths.buildNumber = build
        return Sandbox(root: root, home: home, bundledBin: bundledBin, support: support, launchd: launchd, paths: paths)
    }

    private func plist(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func summary(claude: Bool = true, node: Bool = true, grok: Bool = false) -> DetectionSummary {
        DetectionSummary(
            detectedAt: Date(),
            claude: claude ? .found("Claude Code credentials file") : .missing("Claude Code is not installed"),
            codex: .found("Codex session logs"),
            gemini: .missing("Gemini is not installed"),
            grok: grok ? .found("Grok credentials") : .missing("Grok is not signed in"),
            local: .missing("Ollama is not installed"),
            node: node ? .found("Node.js") : .missing("Node.js is not installed"),
            python3: .found("Python 3")
        )
    }

    // MARK: - 1. Set up from Downloads says why

    func testSetUpFromDownloadsReportsTheRealReasonAndScoresNoLanes() throws {
        let box = try sandbox()
        var paths = box.paths
        paths.appExecutable = box.home.appendingPathComponent("Downloads/Usage HUD.app/Contents/MacOS/CodexUsageHUD").path
        var updates: [[LaneSetupResult]] = []
        let outcome = BackgroundRefreshService.setUpAndRefresh(
            paths: paths,
            providers: ["claude", "codex"],
            waitTimeout: 0,
            onLaneUpdate: { updates.append($0) }
        )
        let blocker = try XCTUnwrap(outcome.blocker)
        XCTAssertTrue(blocker.contains("Downloads"), blocker)
        XCTAssertTrue(blocker.contains("Move Usage HUD to Applications, then open it again."), blocker)
        XCTAssertTrue(outcome.lanes.isEmpty)
        XCTAssertFalse(outcome.hasData)
        XCTAssertEqual(updates.last, [])
        XCTAssertFalse(outcome.report.text.contains("not signed in"), outcome.report.text)
        XCTAssertFalse(fm.fileExists(atPath: box.launchd.path), "nothing may be installed from Downloads")

        let card = SetupCardModel.outcome(summary: summary(), outcome: outcome, hasData: false)
        XCTAssertEqual(card.phase, .blocked)
        XCTAssertTrue(card.isVisible)
        XCTAssertTrue(card.lanes.isEmpty)
        let note = try XCTUnwrap(card.runtimeNote)
        XCTAssertTrue(note.hasPrefix("Set up didn’t run."), note)
        XCTAssertTrue(note.contains("Move Usage HUD to Applications"), note)
        XCTAssertFalse(note.contains("not signed in"))
    }

    func testFinishedSetUpStillShowsLaneResults() {
        let lanes = [LaneSetupResult(provider: "claude", name: "Claude", status: .success("Claude ✓ 9% of the week used"))]
        let outcome = BackgroundRefreshService.SetupOutcome(report: .init(), lanes: lanes, hasData: true)
        let card = SetupCardModel.outcome(summary: summary(), outcome: outcome, hasData: true)
        XCTAssertEqual(card.phase, .doneWithData)
        XCTAssertEqual(card.lanes, lanes)
    }

    func testInstallLocationIssueNamesThePlaceAndTheNextStep() {
        let home = URL(fileURLWithPath: "/Users/buyer name")
        func issue(_ path: String) -> String? {
            BackgroundRefreshService.installLocationIssue(appExecutable: path, home: home)
        }
        let suffix = "/Usage HUD.app/Contents/MacOS/CodexUsageHUD"
        XCTAssertEqual(issue("/Users/buyer name/Downloads" + suffix),
                       "Usage HUD is open from your Downloads folder. Move Usage HUD to Applications, then open it again.")
        XCTAssertTrue(issue("/Users/buyer name/Desktop" + suffix)?.hasPrefix("Usage HUD is open from your Desktop.") == true)
        XCTAssertTrue(issue("/Volumes/Usage HUD" + suffix)?.hasPrefix("Usage HUD is open from a disk image.") == true)
        XCTAssertTrue(issue("/private/var/folders/x/AppTranslocation/A/d" + suffix)?.hasPrefix("macOS opened Usage HUD from a temporary copy.") == true)
        XCTAssertNil(issue("/Applications" + suffix))
        XCTAssertNil(issue("/Users/buyer name/Applications" + suffix))
    }

    func testDamagedCopyBlocksWithADownloadAgainMessage() throws {
        var paths = try sandbox().paths
        paths.bundledBinDirectory = nil
        let report = BackgroundRefreshService.setUp(paths: paths)
        XCTAssertEqual(report.blocker, BackgroundRefreshService.damagedCopyMessage)
    }

    func testBlockedFixturePhaseLoads() throws {
        let dir = try tempDir("fixture")
        try """
        {"phase":"blocked","found":["Claude Code"],"runtimeNote":"Set up didn’t run. Usage HUD is open from your Downloads folder."}
        """.write(to: dir.appendingPathComponent("setup-card.json"), atomically: true, encoding: .utf8)
        let card = try XCTUnwrap(SetupCardModel.loadFixture(from: dir))
        XCTAssertEqual(card.phase, .blocked)
        XCTAssertTrue(card.lanes.isEmpty)
    }

    func testFirstRunSetsItselfUpOnlyWhenItCanAndHasSomethingToRead() {
        XCTAssertTrue(UsageState.shouldAutoRunSetup(installed: false, busy: false, found: ["claude"], locationIssue: nil))
        XCTAssertFalse(UsageState.shouldAutoRunSetup(installed: true, busy: false, found: ["claude"], locationIssue: nil), "already set up")
        XCTAssertFalse(UsageState.shouldAutoRunSetup(installed: false, busy: true, found: ["claude"], locationIssue: nil), "Set up already running")
        XCTAssertFalse(UsageState.shouldAutoRunSetup(installed: false, busy: false, found: [], locationIssue: nil), "no tools: the card explains")
        XCTAssertFalse(UsageState.shouldAutoRunSetup(installed: false, busy: false, found: ["codex"], locationIssue: "Usage HUD is open from your Downloads folder."), "wrong place: the card explains")
    }

    // MARK: - 4. No Keychain heads-up

    func testSetupCardNeverWarnsAboutAKeychainPrompt() {
        // Claude Code writes its sign-in with /usr/bin/security and the app
        // reads it with the same tool, so macOS never asks (clean VM, 10/03).
        for card in [
            SetupCardModel.prompt(summary: summary()),
            SetupCardModel.running(summary: summary()),
            SetupCardModel.live(installed: false, summary: summary(), acknowledged: false),
        ] {
            XCTAssertFalse(card.runtimeNote?.contains("security") == true, card.runtimeNote ?? "")
        }
        // The Node.js note still shows when a Node-only lane was found.
        XCTAssertTrue(SetupCardModel.prompt(summary: summary(node: false, grok: true)).runtimeNote?.contains("Node.js") == true)
    }

    // MARK: - 2. Self-retiring jobs

    private func renderContext(spacey: Bool = true) -> LaunchdTemplateRenderer.Context {
        LaunchdTemplateRenderer.Context(
            home: "/Users/Buyer Name",
            stateDir: "/Users/Buyer Name/.codex-usage-hud",
            binDir: "/Users/Buyer Name/Library/Application Support/Codex Usage HUD/bin",
            supportDir: "/Users/Buyer Name/Library/Application Support/Codex Usage HUD",
            appExecutable: "/Users/Buyer Name/Applications/Usage HUD & Co.app/Contents/MacOS/CodexUsageHUD"
        )
    }

    func testEveryRenderedJobSelfRetiresAndNamesTheApp() throws {
        let context = renderContext()
        for label in Self.renderedLabels {
            let raw = try String(contentsOf: repoTemplates.appendingPathComponent("\(label).plist"), encoding: .utf8)
            let rendered = LaunchdTemplateRenderer.render(raw, context: context)
            let data = Data(rendered.utf8)
            let dict = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                "\(label) must stay a valid plist with spaces and & in paths"
            )
            XCTAssertEqual(dict["Label"] as? String, label)
            XCTAssertEqual(dict["AssociatedBundleIdentifiers"] as? [String], ["com.codexusagehud.app"], label)
            let args = try XCTUnwrap(dict["ProgramArguments"] as? [String], label)
            XCTAssertEqual(Array(args.prefix(2)), ["/bin/bash", "-c"], label)
            XCTAssertTrue(args[2].hasPrefix(LaunchdTemplateRenderer.selfRetireGuard), "\(label): \(args[2])")
            XCTAssertEqual(args[3], label, "$0 must be the job's own label")
            XCTAssertEqual(args[4], context.appExecutable, "$1 is the app path, verbatim, as its own argument")
            if label == "com.codexusagehud.app" {
                XCTAssertEqual(args.count, 5)
                XCTAssertTrue(args[2].hasSuffix(#"exec "$1""#))
            } else {
                XCTAssertEqual(args.count, 6, label)
                XCTAssertTrue(args[2].hasSuffix(#"exec /bin/bash -lc "$2""#), label)
                XCTAssertTrue(args[5].contains("\"\(context.binDir)/"), "\(label): bin paths stay double-quoted")
            }
            // The guard never splices a path into shell source.
            XCTAssertFalse(args[2].contains(context.appExecutable))
            XCTAssertFalse(args[2].contains("Application Support"))
        }
    }

    func testTemplatesKeepMakefilePlaceholdersOnly() throws {
        // `make install` renders these with sed and knows no other placeholder.
        let known: Set<String> = ["%%APP_EXECUTABLE%%", "%%BIN_DIR%%", "%%SUPPORT_DIR%%", "%%STATE_DIR%%", "%%HOME%%"]
        let regex = try NSRegularExpression(pattern: "%%[A-Z_]+%%")
        for label in Self.renderedLabels {
            let raw = try String(contentsOf: repoTemplates.appendingPathComponent("\(label).plist"), encoding: .utf8)
            let found = regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
                .compactMap { Range($0.range, in: raw).map { String(raw[$0]) } }
            XCTAssertTrue(Set(found).isSubset(of: known), "\(label): \(found)")
        }
    }

    /// Runs the real guard with a stub in place of launchctl.
    private func runGuard(label: String, appPath: String, home: URL, command: String) throws -> (status: Int32, stubLog: String) {
        let stubLog = home.appendingPathComponent("launchctl calls.log")
        let stub = home.appendingPathComponent("fake launchctl")
        try "#!/bin/sh\necho \"$@\" >> \"\(stubLog.path)\"\n".write(to: stub, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let script = LaunchdTemplateRenderer.selfRetireGuard
            .replacingOccurrences(of: "/bin/launchctl", with: "'\(stub.path)'")
            .replacingOccurrences(of: "/bin/sleep 10", with: "/bin/sleep 0")
            + #"exec /bin/bash -lc "$2""#
        XCTAssertFalse(script.contains("/bin/launchctl"), "the test must never reach the real launchctl")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script, label, appPath, command]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, (try? String(contentsOf: stubLog, encoding: .utf8)) ?? "")
    }

    func testGuardRetiresTheJobWhenTheAppIsGone() throws {
        let home = try tempDir("home trash")
        let label = "com.codexusagehud.codex-writer"
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        let plistURL = agents.appendingPathComponent("\(label).plist")
        try Data("x".utf8).write(to: plistURL)
        let marker = home.appendingPathComponent("helper ran")
        let missingApp = home.appendingPathComponent("Applications/Usage HUD.app/Contents/MacOS/CodexUsageHUD").path

        let result = try runGuard(label: label, appPath: missingApp, home: home, command: "touch \"\(marker.path)\"")
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(fm.fileExists(atPath: plistURL.path), "the job deletes its own plist")
        XCTAssertEqual(result.stubLog.trimmingCharacters(in: .whitespacesAndNewlines), "bootout gui/\(getuid())/\(label)")
        XCTAssertFalse(fm.fileExists(atPath: marker.path), "the helper must not run once the app is gone")
    }

    func testGuardRunsTheHelperWhileTheAppExists() throws {
        let home = try tempDir("home live")
        let label = "com.codexusagehud.refresh"
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        let plistURL = agents.appendingPathComponent("\(label).plist")
        try Data("x".utf8).write(to: plistURL)
        let app = home.appendingPathComponent("Applications/Usage HUD.app/Contents/MacOS/CodexUsageHUD")
        try fm.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: app)
        let marker = home.appendingPathComponent("Application Support/helper ran")
        try fm.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)

        let result = try runGuard(label: label, appPath: app.path, home: home, command: "touch \"\(marker.path)\"")
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(fm.fileExists(atPath: marker.path), "the helper runs with spaces in every path")
        XCTAssertTrue(fm.fileExists(atPath: plistURL.path))
        XCTAssertEqual(result.stubLog, "")
    }

    // MARK: - 3. Helper refresh after an update

    func testSetUpWritesAStampAndAFreshInstallNeedsNoRefresh() throws {
        let box = try sandbox()
        _ = BackgroundRefreshService.setUp(paths: box.paths, providers: ["codex"])
        let stamp = try XCTUnwrap(BackgroundRefreshService.loadStamp(paths: box.paths))
        XCTAssertEqual(stamp.build, "7")
        XCTAssertEqual(stamp.appExecutable, box.paths.appExecutable)
        XCTAssertEqual(stamp, BackgroundRefreshService.currentStamp(paths: box.paths))
        XCTAssertNil(BackgroundRefreshService.refreshInstalledHelpersIfStale(paths: box.paths))

        let codex = try plist(box.launchd.appendingPathComponent("com.codexusagehud.codex-writer.plist"))
        XCTAssertEqual(codex["AssociatedBundleIdentifiers"] as? [String], ["com.codexusagehud.app"])
    }

    func testChangedHelpersAreRecopiedAndOnlyInstalledJobsReRendered() throws {
        let box = try sandbox()
        _ = BackgroundRefreshService.setUp(paths: box.paths, providers: ["codex"])
        XCTAssertFalse(fm.fileExists(atPath: box.launchd.appendingPathComponent("com.codexusagehud.grok-writer.plist").path))

        try "#!/bin/sh\necho v2\n".write(to: box.bundledBin.appendingPathComponent("codex-usage-refresh"), atomically: true, encoding: .utf8)
        let report = try XCTUnwrap(BackgroundRefreshService.refreshInstalledHelpersIfStale(paths: box.paths))
        XCTAssertTrue(report.text.contains("com.codexusagehud.codex-writer: plist written"), report.text)
        XCTAssertFalse(report.text.contains("grok-writer"), "a job that was never installed stays uninstalled")
        let copied = try String(contentsOf: box.support.appendingPathComponent("bin/codex-usage-refresh"), encoding: .utf8)
        XCTAssertTrue(copied.contains("v2"))
        XCTAssertFalse(fm.fileExists(atPath: box.launchd.appendingPathComponent("com.codexusagehud.grok-writer.plist").path))
        XCTAssertNil(BackgroundRefreshService.refreshInstalledHelpersIfStale(paths: box.paths), "the new stamp is current")
    }

    func testNewBuildOrMovedAppRefreshes() throws {
        let box = try sandbox()
        _ = BackgroundRefreshService.setUp(paths: box.paths, providers: ["codex"])

        var newBuild = box.paths
        newBuild.buildNumber = "8"
        XCTAssertNotNil(BackgroundRefreshService.refreshInstalledHelpersIfStale(paths: newBuild))
        XCTAssertEqual(BackgroundRefreshService.loadStamp(paths: newBuild)?.build, "8")

        var moved = newBuild
        moved.appExecutable = "/Applications/Usage HUD.app/Contents/MacOS/CodexUsageHUD"
        XCTAssertNotNil(BackgroundRefreshService.refreshInstalledHelpersIfStale(paths: moved))
        let args = try plist(box.launchd.appendingPathComponent("com.codexusagehud.codex-writer.plist"))["ProgramArguments"] as? [String]
        XCTAssertEqual(args?[4], moved.appExecutable, "jobs now guard the app's new location")
    }

    func testPreStampInstallGetsTheGuardOnFirstLaunch() throws {
        let box = try sandbox()
        // What an older Set up left behind: an old-style plist that runs the
        // copied helpers, and no stamp.
        try fm.createDirectory(at: box.launchd, withIntermediateDirectories: true)
        try fm.createDirectory(at: box.support.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let old = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Label</key><string>com.codexusagehud.codex-writer</string>
        <key>ProgramArguments</key><array><string>/bin/bash</string><string>-lc</string>
        <string>exec bash "\(box.support.path)/bin/codex-usage-write"</string></array></dict></plist>
        """
        try old.write(to: box.launchd.appendingPathComponent("com.codexusagehud.codex-writer.plist"), atomically: true, encoding: .utf8)

        XCTAssertNotNil(BackgroundRefreshService.refreshInstalledHelpersIfStale(paths: box.paths))
        let dict = try plist(box.launchd.appendingPathComponent("com.codexusagehud.codex-writer.plist"))
        XCTAssertEqual(dict["AssociatedBundleIdentifiers"] as? [String], ["com.codexusagehud.app"])
        XCTAssertTrue((dict["ProgramArguments"] as? [String])?[2].hasPrefix(LaunchdTemplateRenderer.selfRetireGuard) == true)
        XCTAssertNotNil(BackgroundRefreshService.loadStamp(paths: box.paths))
    }

    func testMakefileInstalledJobsAreNeverTouched() throws {
        let box = try sandbox()
        try fm.createDirectory(at: box.launchd, withIntermediateDirectories: true)
        // `make install` points every job at ~/.local/bin, not the app's copy.
        let owner = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Label</key><string>com.codexusagehud.codex-writer</string>
        <key>ProgramArguments</key><array><string>/bin/bash</string><string>-lc</string>
        <string>exec bash "\(box.home.path)/.local/bin/codex-usage-write"</string></array></dict></plist>
        """
        let url = box.launchd.appendingPathComponent("com.codexusagehud.codex-writer.plist")
        try owner.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertNil(BackgroundRefreshService.refreshInstalledHelpersIfStale(paths: box.paths))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), owner)
        XCTAssertFalse(fm.fileExists(atPath: box.support.appendingPathComponent("bin").path))
        XCTAssertNil(BackgroundRefreshService.loadStamp(paths: box.paths))
    }

    func testRefreshNeverPointsJobsAtACopyOutsideApplications() throws {
        let box = try sandbox()
        _ = BackgroundRefreshService.setUp(paths: box.paths, providers: ["codex"])
        var downloads = box.paths
        downloads.appExecutable = box.home.appendingPathComponent("Downloads/Usage HUD.app/Contents/MacOS/CodexUsageHUD").path
        downloads.buildNumber = "9"
        XCTAssertNil(BackgroundRefreshService.refreshInstalledHelpersIfStale(paths: downloads))
    }

    func testRefreshIsOnlyAllowedWithBothTestDirsOrNone() {
        let home = URL(fileURLWithPath: "/Users/buyer")
        XCTAssertTrue(BackgroundRefreshService.helperRefreshAllowed(env: [:], home: home))
        XCTAssertTrue(BackgroundRefreshService.helperRefreshAllowed(
            env: ["CODEX_USAGE_HUD_LAUNCHD_DIR": "/tmp/a", "CODEX_USAGE_HUD_SUPPORT_DIR": "/tmp/b"], home: home))
        XCTAssertFalse(BackgroundRefreshService.helperRefreshAllowed(env: ["CODEX_USAGE_HUD_LAUNCHD_DIR": "/tmp/a"], home: home))
        XCTAssertFalse(BackgroundRefreshService.helperRefreshAllowed(env: ["CODEX_USAGE_HUD_SUPPORT_DIR": "/tmp/b"], home: home))
        XCTAssertFalse(BackgroundRefreshService.helperRefreshAllowed(
            env: ["CODEX_USAGE_HUD_LAUNCHD_DIR": "", "CODEX_USAGE_HUD_SUPPORT_DIR": "/tmp/b"], home: home))
        // A throwaway state dir must never be written into the real jobs.
        XCTAssertFalse(BackgroundRefreshService.helperRefreshAllowed(env: ["CODEX_USAGE_HUD_STATE_DIR": "/tmp/fixture"], home: home))
        XCTAssertTrue(BackgroundRefreshService.helperRefreshAllowed(env: ["CODEX_USAGE_HUD_STATE_DIR": "~/.codex-usage-hud"], home: home))
    }

    func testDigestChangesWithContentAndName() throws {
        let dir = try tempDir("digest")
        try "a".write(to: dir.appendingPathComponent("one"), atomically: true, encoding: .utf8)
        let first = BackgroundRefreshService.helpersDigest(directories: [dir])
        XCTAssertEqual(first, BackgroundRefreshService.helpersDigest(directories: [dir]))
        try "b".write(to: dir.appendingPathComponent("one"), atomically: true, encoding: .utf8)
        let second = BackgroundRefreshService.helpersDigest(directories: [dir])
        XCTAssertNotEqual(first, second)
        try fm.moveItem(at: dir.appendingPathComponent("one"), to: dir.appendingPathComponent("two"))
        XCTAssertNotEqual(second, BackgroundRefreshService.helpersDigest(directories: [dir]))
    }

    // MARK: - Open at login and Remove

    func testOpenAtLoginWritesAndDeletesOnlyTheAppLoginItem() throws {
        let box = try sandbox()
        XCTAssertFalse(BackgroundRefreshService.isOpenAtLoginEnabled(paths: box.paths))
        let on = BackgroundRefreshService.setOpenAtLogin(true, paths: box.paths)
        XCTAssertNil(on.blocker, on.text)
        XCTAssertTrue(BackgroundRefreshService.isOpenAtLoginEnabled(paths: box.paths))
        let dict = try plist(box.launchd.appendingPathComponent("com.codexusagehud.app.plist"))
        XCTAssertEqual((dict["ProgramArguments"] as? [String])?[4], box.paths.appExecutable)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: box.launchd.path), ["com.codexusagehud.app.plist"])
        // A login item alone is not a Set up: the card must still offer it.
        XCTAssertFalse(BackgroundRefreshService.isInstalled(paths: box.paths))
        XCTAssertNil(BackgroundRefreshService.refreshInstalledHelpersIfStale(paths: box.paths))

        _ = BackgroundRefreshService.setOpenAtLogin(false, paths: box.paths)
        XCTAssertFalse(BackgroundRefreshService.isOpenAtLoginEnabled(paths: box.paths))
    }

    func testSetUpAgainKeepsOpenAtLoginOff() throws {
        let box = try sandbox()
        _ = BackgroundRefreshService.setUp(paths: box.paths, providers: ["codex"])
        XCTAssertTrue(BackgroundRefreshService.isOpenAtLoginEnabled(paths: box.paths), "first Set up turns it on")
        _ = BackgroundRefreshService.setOpenAtLogin(false, paths: box.paths)
        let again = BackgroundRefreshService.setUp(paths: box.paths, providers: ["codex"])
        XCTAssertTrue(again.text.contains("com.codexusagehud.app: skipped (Open at login is off)"), again.text)
        XCTAssertFalse(BackgroundRefreshService.isOpenAtLoginEnabled(paths: box.paths))
        XCTAssertTrue(BackgroundRefreshService.isInstalled(paths: box.paths))
    }

    func testOpenAtLoginRefusesACopyInDownloads() throws {
        var paths = try sandbox().paths
        paths.appExecutable = paths.home.appendingPathComponent("Downloads/Usage HUD.app/Contents/MacOS/CodexUsageHUD").path
        let report = BackgroundRefreshService.setOpenAtLogin(true, paths: paths)
        XCTAssertNotNil(report.blocker)
        XCTAssertFalse(BackgroundRefreshService.isOpenAtLoginEnabled(paths: paths))
    }

    func testOldSetUpWithoutNodeStillCountsAsInstalled() throws {
        let box = try sandbox(nodeAvailable: false)
        _ = BackgroundRefreshService.setUp(paths: box.paths, providers: ["claude", "codex"])
        // Without Node.js only the app's own plist is written.
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: box.launchd.path), ["com.codexusagehud.app.plist"])
        XCTAssertTrue(BackgroundRefreshService.isInstalled(paths: box.paths))
        try fm.removeItem(at: BackgroundRefreshService.stampURL(paths: box.paths))
        XCTAssertTrue(BackgroundRefreshService.isInstalled(paths: box.paths), "copied helpers prove an older Set up ran")
    }

    func testRemoveDeletesJobsHelpersAndStampButLeavesTheAppRunning() throws {
        let box = try sandbox()
        _ = BackgroundRefreshService.setUp(paths: box.paths, providers: ["codex"])
        let report = BackgroundRefreshService.remove(paths: box.paths)
        XCTAssertTrue(report.text.contains("com.codexusagehud.app: left running"), report.text)
        XCTAssertFalse(report.text.contains("com.codexusagehud.app: unloaded"))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: box.launchd.path), [])
        XCTAssertFalse(fm.fileExists(atPath: box.support.appendingPathComponent("bin").path))
        XCTAssertNil(BackgroundRefreshService.loadStamp(paths: box.paths))
        XCTAssertFalse(BackgroundRefreshService.isInstalled(paths: box.paths))
    }


    func testDiagnosticsWithoutNodeExplainsInsteadOfRunningShim() throws {
        let box = try sandbox(nodeAvailable: false)
        let supportBin = box.support.appendingPathComponent("bin")
        try fm.createDirectory(at: supportBin, withIntermediateDirectories: true)
        for directory in [supportBin, box.bundledBin] {
            for helper in ["bloom-node", "codex-usage-doctor"] {
                let path = directory.appendingPathComponent(helper)
                try "#!/bin/sh\nprintf 'FAIL stub helper ran\\n'\n".write(to: path, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
            }
        }
        let result = BackgroundRefreshService.runDiagnostics(paths: box.paths)
        XCTAssertTrue(result.text.contains("Node.js 18"), result.text)
        XCTAssertTrue(result.text.contains("Claude and Codex"), result.text)
        XCTAssertFalse(result.text.contains("stub helper ran"), result.text)
    }

    func testDiagnosticsPrefersNewBundledHelperOverCopiedHelper() throws {
        let box = try sandbox()
        let supportBin = box.support.appendingPathComponent("bin")
        try fm.createDirectory(at: supportBin, withIntermediateDirectories: true)
        try fm.createDirectory(at: box.bundledBin, withIntermediateDirectories: true)
        let scripts = [
            (supportBin.appendingPathComponent("codex-usage-doctor"), "#!/bin/sh\nprintf 'FAIL stale: old copied helper\\n'\n"),
            (box.bundledBin.appendingPathComponent("codex-usage-doctor"), "#!/bin/sh\nprintf 'OK bundled: current helper\\n'\n"),
            (supportBin.appendingPathComponent("bloom-node"), "#!/bin/sh\nexec /bin/sh \"$@\"\n")
        ]
        for (path, contents) in scripts {
            try contents.write(to: path, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        let result = BackgroundRefreshService.runDiagnostics(paths: box.paths)
        XCTAssertTrue(result.text.contains("OK bundled"), result.text)
        XCTAssertFalse(result.text.contains("FAIL stale"), result.text)
    }

    // MARK: - Settings results in plain words

    func testDiagnosticsHeadlineCountsChecksAndKeepsRawOutputForDetails() {
        let output = "OK  claude windows: week 42%\nWARN  grok writer log: 2 errors\nFAIL  com.codexusagehud.app: not loaded in launchd\nOK  codex windows: ok"
        let result = BackgroundJobsModel.diagnosticsResult(output)
        XCTAssertEqual(result.headline, "Health check: 2 passed · 1 warning · 1 problem.")
        XCTAssertTrue(result.isWarning)
        XCTAssertEqual(result.details, output)
        XCTAssertTrue(result.lines.contains { $0.contains("Node.js 18") })
        XCTAssertTrue(result.lines.contains { $0.contains("Open Usage HUD from Applications") })
        XCTAssertNotNil(result.supportReport)
        XCTAssertEqual(BackgroundJobsModel.diagnosticsResult("OK  a: b\nOK  c: d").headline, "All 2 checks passed.")
        XCTAssertEqual(BackgroundJobsModel.diagnosticsResult("OK  a: b").headline, "1 check passed.")
        let message = BackgroundJobsModel.diagnosticsResult("Set up first so the health check is available.")
        XCTAssertEqual(message.headline, "Set up first so the health check is available.")
    }

    @MainActor
    func testResetPingCopySaysUsageHUD() {
        let notice = ResetPingController.deniedNotice
        XCTAssertFalse(notice.contains("Codex Usage HUD"))
        XCTAssertTrue(notice.contains("Usage HUD"))
    }

    // MARK: - 5. Lanes from older builds are dropped silently

    func testPreferencesFromAnOlderBuildWithRetiredLanesStillLoad() throws {
        let state = try tempDir("buyer state")
        let previous = ProcessInfo.processInfo.environment["CODEX_USAGE_HUD_STATE_DIR"]
        setenv("CODEX_USAGE_HUD_STATE_DIR", state.path, 1)
        addTeardownBlock {
            if let previous { setenv("CODEX_USAGE_HUD_STATE_DIR", previous, 1) } else { unsetenv("CODEX_USAGE_HUD_STATE_DIR") }
        }
        XCTAssertTrue(UsagePaths.isIsolatedStateDir)
        XCTAssertEqual(ProviderCatalog.displayProviders.map(\.id), ["codex", "claude", "gemini", "grok", "local"])

        // Preferences an older build stored, listing lanes this build no longer has.
        let prefs = ProviderPreferencesFile(
            detectedAt: nil, found: ["Claude Code", "Old Lane"], missing: [],
            connected: ["claude", "old-lane", "other-old-lane"], shown: ["claude", "old-lane", "other-old-lane"],
            setupCompleteAcknowledged: nil, nodeAvailable: true, pythonAvailable: true, runtimeNote: nil
        )
        let data = try JSONEncoder().encode(prefs)
        try data.write(to: state.appendingPathComponent(ProviderPreferences.fileName))
        let selection = ProviderPreferences.selection()
        XCTAssertEqual(selection.shown, ["claude"])
        XCTAssertEqual(selection.connected, ["claude"])
        XCTAssertEqual(UsageInsights.visibleProviderOrder(snapshots: [], selection: selection), ["claude"])
        let summary = try XCTUnwrap(ProviderPreferences.detectionSummary())
        XCTAssertTrue(summary.claude.isFound)
        XCTAssertEqual(summary.foundLine, "Found: Claude Code")
        XCTAssertFalse(summary.isFound("old-lane"))
    }
}
