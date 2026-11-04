import XCTest
@testable import CodexUsageHUD

final class SliceA2Tests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testPlistRendererSubstitutesHomeAndBinPath() {
        let template = """
        home=%%HOME%%
        bin=%%BIN_DIR%%
        state=%%STATE_DIR%%
        support=%%SUPPORT_DIR%%
        app=%%APP_EXECUTABLE%%
        """
        let rendered = LaunchdTemplateRenderer.render(
            template,
            context: .init(
                home: "/tmp/buyer-home",
                stateDir: "/tmp/buyer-home/.codex-usage-hud",
                binDir: "/tmp/buyer-support/bin",
                supportDir: "/tmp/buyer-support",
                appExecutable: "/tmp/buyer-home/Applications/CodexUsageHUD.app/Contents/MacOS/CodexUsageHUD"
            )
        )
        XCTAssertEqual(rendered.contains("%%"), false)
        XCTAssertTrue(rendered.contains("/tmp/buyer-home"))
        XCTAssertTrue(rendered.contains("/tmp/buyer-support/bin"))
        XCTAssertFalse(rendered.contains("/Users/"))
        XCTAssertFalse(rendered.contains(NSHomeDirectory()))
    }

    func testLaunchdTemplatesHaveNoThisMacAbsolutePath() throws {
        let launchd = repoRoot.appendingPathComponent("launchd")
        let items = try FileManager.default.contentsOfDirectory(at: launchd, includingPropertiesForKeys: nil)
        let plists = items.filter { $0.pathExtension == "plist" }
        XCTAssertFalse(plists.isEmpty)
        let home = NSHomeDirectory()
        for plist in plists {
            let text = try String(contentsOf: plist, encoding: .utf8)
            XCTAssertFalse(text.contains(home), "template leaked \(home) in \(plist.lastPathComponent)")
            XCTAssertFalse(text.contains("/Users/"), plist.lastPathComponent)
        }
        let core = [
            "com.codexusagehud.app.plist",
            "com.codexusagehud.codex-writer.plist",
            "com.codexusagehud.claude-writer.plist",
            "com.codexusagehud.grok-writer.plist",
            "com.codexusagehud.refresh.plist",
        ]
        for name in core {
            let text = try String(contentsOf: launchd.appendingPathComponent(name), encoding: .utf8)
            XCTAssertTrue(text.contains("%%HOME%%") || name == "com.codexusagehud.app.plist")
            XCTAssertTrue(text.contains("%%BIN_DIR%%") || name == "com.codexusagehud.app.plist")
            XCTAssertTrue(text.contains("%%STATE_DIR%%"))
            if name == "com.codexusagehud.app.plist" {
                XCTAssertTrue(text.contains("%%APP_EXECUTABLE%%"))
            }
            if name == "com.codexusagehud.claude-writer.plist" {
                XCTAssertTrue(text.contains("bloom-usage-fetch-claude-official"))
                XCTAssertTrue(text.contains("--mode api"))
            }
        }
    }

    func testDependencyDetectionUsesFakePATHOnly() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("hud-dep-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let node = bin.appendingPathComponent("node")
        try "#!/bin/sh\nexit 0\n".write(to: node, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)

        let python = bin.appendingPathComponent("python3")
        try "#!/bin/sh\nexit 0\n".write(to: python, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)

        let found = RuntimeDependencies.Probe.isolated(
            env: ["PATH": bin.path],
            home: root
        )
        XCTAssertEqual(RuntimeDependencies.resolveNode(probe: found, fileManager: fm)?.path, node.path)
        XCTAssertEqual(RuntimeDependencies.resolvePython3(probe: found, fileManager: fm)?.path, python.path)

        let missing = RuntimeDependencies.Probe.isolated(
            env: ["PATH": "/tmp/hud-empty-path-\(UUID().uuidString)"],
            home: root
        )
        XCTAssertNil(RuntimeDependencies.resolveNode(probe: missing, fileManager: fm))
        XCTAssertNil(RuntimeDependencies.resolvePython3(probe: missing, fileManager: fm))

        let extraNode = root.appendingPathComponent("extra-node")
        try "#!/bin/sh\nexit 0\n".write(to: extraNode, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: extraNode.path)
        let viaExtra = RuntimeDependencies.Probe.isolated(
            env: ["PATH": ""],
            home: root,
            extraNode: [extraNode]
        )
        XCTAssertEqual(RuntimeDependencies.resolveNode(probe: viaExtra, fileManager: fm)?.path, extraNode.path)
    }

    func testUsrBinPython3RequiresCommandLineTools() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("hud-clt-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Only /usr/bin/python3 is offered as a candidate; it exists on any
        // Mac (stub or real), so this isolates the Command Line Tools gate.
        let usrBinPython3 = URL(fileURLWithPath: "/usr/bin/python3")

        let withoutTools = RuntimeDependencies.Probe.isolated(
            env: ["PATH": "/tmp/hud-empty-path-\(UUID().uuidString)"],
            home: root,
            extraPython: [usrBinPython3],
            commandLineToolsInstalled: { false }
        )
        XCTAssertNil(RuntimeDependencies.resolvePython3(probe: withoutTools, fileManager: fm))

        let withTools = RuntimeDependencies.Probe.isolated(
            env: ["PATH": "/tmp/hud-empty-path-\(UUID().uuidString)"],
            home: root,
            extraPython: [usrBinPython3],
            commandLineToolsInstalled: { true }
        )
        XCTAssertEqual(RuntimeDependencies.resolvePython3(probe: withTools, fileManager: fm)?.path, usrBinPython3.path)
    }

    func testInstallLocationIssueBlocksTranslocatedOrOutsideApplications() {
        let home = URL(fileURLWithPath: "/tmp/buyer-home-\(UUID().uuidString)")
        let translocated = "/private/var/folders/xx/AppTranslocation/ABCD/d/CodexUsageHUD.app/Contents/MacOS/CodexUsageHUD"
        XCTAssertNotNil(BackgroundRefreshService.installLocationIssue(appExecutable: translocated, home: home))

        let downloads = home.appendingPathComponent("Downloads/CodexUsageHUD.app/Contents/MacOS/CodexUsageHUD").path
        XCTAssertNotNil(BackgroundRefreshService.installLocationIssue(appExecutable: downloads, home: home))

        let systemApplications = "/Applications/CodexUsageHUD.app/Contents/MacOS/CodexUsageHUD"
        XCTAssertNil(BackgroundRefreshService.installLocationIssue(appExecutable: systemApplications, home: home))

        let userApplications = home.appendingPathComponent("Applications/CodexUsageHUD.app/Contents/MacOS/CodexUsageHUD").path
        XCTAssertNil(BackgroundRefreshService.installLocationIssue(appExecutable: userApplications, home: home))
    }

    func testSetUpRefusesToWritePlistsFromATranslocatedCopy() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("hud-translocated-\(UUID().uuidString)")
        let bundledBin = root.appendingPathComponent("bundled-bin")
        let templates = root.appendingPathComponent("templates")
        try fm.createDirectory(at: bundledBin, withIntermediateDirectories: true)
        try fm.createDirectory(at: templates, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let home = URL(fileURLWithPath: "/tmp/buyer-home-\(UUID().uuidString)")
        let launchd = root.appendingPathComponent("launchd")
        let paths = BackgroundRefreshService.Paths(
            supportDirectory: root.appendingPathComponent("support"),
            launchdDirectory: launchd,
            bundledBinDirectory: bundledBin,
            templateDirectory: templates,
            home: home,
            stateDirectory: home.appendingPathComponent(".codex-usage-hud"),
            appExecutable: "/private/var/folders/xx/AppTranslocation/ABCD/d/CodexUsageHUD.app/Contents/MacOS/CodexUsageHUD",
            invokeLaunchctl: false,
            nodeAvailable: true,
            pythonAvailable: true
        )
        let report = BackgroundRefreshService.setUp(paths: paths, fileManager: fm)
        XCTAssertTrue(report.text.contains("Move Usage HUD to Applications"), report.text)
        XCTAssertFalse(fm.fileExists(atPath: launchd.path))
    }

    func testSetUpHonorsLaunchdAndSupportOverridesAndSkipsLaunchctl() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("hud-setup-\(UUID().uuidString)")
        let bundledBin = root.appendingPathComponent("bundled-bin")
        let templates = root.appendingPathComponent("templates")
        let support = root.appendingPathComponent("support")
        let launchd = root.appendingPathComponent("launchd")
        let home = URL(fileURLWithPath: "/tmp/buyer-home-\(UUID().uuidString)")
        try fm.createDirectory(at: bundledBin, withIntermediateDirectories: true)
        try fm.createDirectory(at: templates, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try "#!/bin/sh\necho ok\n".write(to: bundledBin.appendingPathComponent("codex-usage-refresh"), atomically: true, encoding: .utf8)
        let template = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>Label</key><string>LABEL</string>
        <key>Bin</key><string>%%BIN_DIR%%</string>
        <key>Home</key><string>%%HOME%%</string>
        <key>State</key><string>%%STATE_DIR%%</string>
        </dict></plist>
        """
        for label in BundledHelpers.coreLaunchdLabels {
            let body = template.replacingOccurrences(of: "LABEL", with: label)
            try body.write(to: templates.appendingPathComponent("\(label).plist"), atomically: true, encoding: .utf8)
        }

        let paths = BackgroundRefreshService.Paths(
            supportDirectory: support,
            launchdDirectory: launchd,
            bundledBinDirectory: bundledBin,
            templateDirectory: templates,
            home: home,
            stateDirectory: home.appendingPathComponent(".codex-usage-hud"),
            appExecutable: home.appendingPathComponent("Applications/CodexUsageHUD.app/Contents/MacOS/CodexUsageHUD").path,
            invokeLaunchctl: false,
            nodeAvailable: true,
            pythonAvailable: false
        )
        let report = BackgroundRefreshService.setUp(paths: paths, fileManager: fm)
        XCTAssertTrue(report.text.contains("launchctl skipped"), report.text)
        XCTAssertTrue(report.text.contains("com.codexusagehud.claude-writer: skipped (needs Python 3)"), report.text)
        XCTAssertTrue(fm.fileExists(atPath: support.appendingPathComponent("bin/codex-usage-refresh").path))

        let codexPlist = try String(contentsOf: launchd.appendingPathComponent("com.codexusagehud.codex-writer.plist"), encoding: .utf8)
        XCTAssertTrue(codexPlist.contains(support.appendingPathComponent("bin").path))
        XCTAssertTrue(codexPlist.contains(home.path))
        XCTAssertFalse(codexPlist.contains(NSHomeDirectory()))
        XCTAssertFalse(fm.fileExists(atPath: launchd.appendingPathComponent("com.codexusagehud.claude-writer.plist").path))

        let removed = BackgroundRefreshService.remove(paths: paths, fileManager: fm)
        XCTAssertTrue(removed.text.contains("launchctl skipped"), removed.text)
        XCTAssertFalse(fm.fileExists(atPath: launchd.appendingPathComponent("com.codexusagehud.codex-writer.plist").path))
    }

    func testSetUpOnlyInstallsWritersForDetectedProviders() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("hud-detected-\(UUID().uuidString)")
        let bundledBin = root.appendingPathComponent("bundled-bin")
        let templates = root.appendingPathComponent("templates")
        let launchd = root.appendingPathComponent("launchd")
        let home = URL(fileURLWithPath: "/tmp/buyer-home-\(UUID().uuidString)")
        try fm.createDirectory(at: bundledBin, withIntermediateDirectories: true)
        try fm.createDirectory(at: templates, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try "#!/bin/sh\necho ok\n".write(to: bundledBin.appendingPathComponent("codex-usage-refresh"), atomically: true, encoding: .utf8)
        let template = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Label</key><string>LABEL</string></dict></plist>
        """
        for label in BundledHelpers.coreLaunchdLabels {
            try template.replacingOccurrences(of: "LABEL", with: label)
                .write(to: templates.appendingPathComponent("\(label).plist"), atomically: true, encoding: .utf8)
        }
        let paths = BackgroundRefreshService.Paths(
            supportDirectory: root.appendingPathComponent("support"),
            launchdDirectory: launchd,
            bundledBinDirectory: bundledBin,
            templateDirectory: templates,
            home: home,
            stateDirectory: home.appendingPathComponent(".codex-usage-hud"),
            appExecutable: home.appendingPathComponent("Applications/CodexUsageHUD.app/Contents/MacOS/CodexUsageHUD").path,
            invokeLaunchctl: false,
            nodeAvailable: true,
            pythonAvailable: true
        )
        // Claude and Codex were detected; Grok was not — the Grok writer
        // must not install even though Node is available.
        let report = BackgroundRefreshService.setUp(paths: paths, providers: ["claude", "codex"], fileManager: fm)
        XCTAssertTrue(report.text.contains("com.codexusagehud.grok-writer: skipped (not detected)"), report.text)
        XCTAssertTrue(fm.fileExists(atPath: launchd.appendingPathComponent("com.codexusagehud.claude-writer.plist").path))
        XCTAssertTrue(fm.fileExists(atPath: launchd.appendingPathComponent("com.codexusagehud.codex-writer.plist").path))
        XCTAssertFalse(fm.fileExists(atPath: launchd.appendingPathComponent("com.codexusagehud.grok-writer.plist").path))
    }

    func testSkipReasonMatchesMissingRuntimes() {
        let claude = BackgroundRefreshService.agents.first { $0.label == "com.codexusagehud.claude-writer" }!
        let codex = BackgroundRefreshService.agents.first { $0.label == "com.codexusagehud.codex-writer" }!
        let app = BackgroundRefreshService.agents.first { $0.label == "com.codexusagehud.app" }!
        XCTAssertEqual(BackgroundRefreshService.skipReason(agent: claude, nodeAvailable: true, pythonAvailable: false), "needs Python 3")
        XCTAssertEqual(BackgroundRefreshService.skipReason(agent: codex, nodeAvailable: false, pythonAvailable: true), "needs Node.js")
        XCTAssertNil(BackgroundRefreshService.skipReason(agent: app, nodeAvailable: false, pythonAvailable: false))
    }

    func testBundleCompletenessSourceAndPackagedApp() throws {
        let fm = FileManager.default
        let list = try String(contentsOf: repoRoot.appendingPathComponent("Resources/bundled-helpers.txt"), encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        XCTAssertEqual(Set(list), Set(BundledHelpers.scriptNames))
        for name in BundledHelpers.scriptNames {
            let path = repoRoot.appendingPathComponent("bin").appendingPathComponent(name)
            XCTAssertTrue(fm.isReadableFile(atPath: path.path), "missing source helper \(name)")
        }

        let packaged = repoRoot.appendingPathComponent("dist/CodexUsageHUD.app/Contents/Resources/bin")
        if fm.fileExists(atPath: packaged.path) {
            for name in BundledHelpers.scriptNames {
                XCTAssertTrue(
                    fm.isReadableFile(atPath: packaged.appendingPathComponent(name).path),
                    "packaged app missing \(name)"
                )
            }
        }
    }
}
