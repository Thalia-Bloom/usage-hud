import XCTest
@testable import CodexUsageHUD

/// The app's own login item goes through macOS (`SystemLoginItem`) so it
/// shows as Usage HUD, not "bash" from an "Unknown Developer". Every test
/// uses a fake item and temp dirs; nothing touches real login items.
final class LoginItemTests: XCTestCase {
    private let fm = FileManager.default
    private let appLabel = BackgroundRefreshService.appAgentLabel

    private var repoTemplates: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("launchd")
    }

    private final class FakeItem {
        var enabled = false
        var registerError: Error?
        var registers = 0
        var unregisters = 0
        var item: SystemLoginItem {
            SystemLoginItem(
                isEnabled: { [unowned self] in self.enabled },
                register: { [unowned self] in
                    self.registers += 1
                    if let registerError = self.registerError { throw registerError }
                    self.enabled = true
                },
                unregister: { [unowned self] in self.unregisters += 1; self.enabled = false }
            )
        }
    }

    private func paths(item: FakeItem?, nodeAvailable: Bool = false) throws -> BackgroundRefreshService.Paths {
        let root = fm.temporaryDirectory.appendingPathComponent("hud login \(UUID().uuidString)")
        addTeardownBlock { [fm] in try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let bundledBin = root.appendingPathComponent("Usage HUD.app/Contents/Resources/bin")
        try fm.createDirectory(at: bundledBin, withIntermediateDirectories: true)
        try "#!/bin/sh\necho v1\n".write(to: bundledBin.appendingPathComponent("codex-usage-refresh"), atomically: true, encoding: .utf8)
        var paths = BackgroundRefreshService.Paths(
            supportDirectory: home.appendingPathComponent("Library/Application Support/Codex Usage HUD"),
            launchdDirectory: root.appendingPathComponent("LaunchAgents"),
            bundledBinDirectory: bundledBin,
            templateDirectory: repoTemplates,
            home: home,
            stateDirectory: home.appendingPathComponent(".codex-usage-hud"),
            appExecutable: home.appendingPathComponent("Applications/Usage HUD.app/Contents/MacOS/CodexUsageHUD").path,
            invokeLaunchctl: false,
            nodeAvailable: nodeAvailable,
            pythonAvailable: false
        )
        paths.systemLoginItem = item?.item
        return paths
    }

    private func legacyPlist(_ paths: BackgroundRefreshService.Paths) -> URL {
        paths.launchdDirectory.appendingPathComponent("\(appLabel).plist")
    }

    func testSetUpWithoutNodeUsesTheMacOSLoginItemAndStillCountsAsInstalled() throws {
        let fake = FakeItem()
        let paths = try paths(item: fake)
        let report = BackgroundRefreshService.setUp(paths: paths, providers: ["claude", "codex"])
        XCTAssertNil(report.blocker, report.text)
        XCTAssertEqual(fake.registers, 1)
        XCTAssertFalse(fm.fileExists(atPath: legacyPlist(paths).path), "no bash-wrapper plist")
        XCTAssertTrue(BackgroundRefreshService.isInstalled(paths: paths), "the stamp proves Set up ran")
        XCTAssertTrue(BackgroundRefreshService.isOpenAtLoginEnabled(paths: paths))
    }

    func testSetUpFallsBackToThePlistWhenMacOSRefuses() throws {
        let fake = FakeItem()
        fake.registerError = NSError(domain: "SMAppServiceErrorDomain", code: 1)
        let paths = try paths(item: fake)
        _ = BackgroundRefreshService.setUp(paths: paths, providers: ["claude"])
        XCTAssertTrue(fm.fileExists(atPath: legacyPlist(paths).path))
        XCTAssertTrue(BackgroundRefreshService.isOpenAtLoginEnabled(paths: paths))
    }

    func testRepeatSetUpKeepsOpenAtLoginOffWhenTheUserTurnedItOff() throws {
        let fake = FakeItem()
        let paths = try paths(item: fake)
        _ = BackgroundRefreshService.setUp(paths: paths, providers: ["codex"])
        _ = BackgroundRefreshService.setOpenAtLogin(false, paths: paths)
        XCTAssertEqual(fake.unregisters, 1)
        XCTAssertFalse(BackgroundRefreshService.isOpenAtLoginEnabled(paths: paths))
        XCTAssertTrue(BackgroundRefreshService.isInstalled(paths: paths), "Open at login off is still a finished Set up")
        _ = BackgroundRefreshService.setUp(paths: paths, providers: ["codex"])
        XCTAssertEqual(fake.registers, 1, "not turned back on")
    }

    func testOldBashWrapperPlistMovesToTheMacOSLoginItem() throws {
        // A 1.2.0-era Set up: the plist runs the app through /bin/bash.
        let paths = try paths(item: nil)
        _ = BackgroundRefreshService.setUp(paths: paths, providers: ["codex"])
        XCTAssertTrue(fm.fileExists(atPath: legacyPlist(paths).path))

        let fake = FakeItem()
        var upgraded = paths
        upgraded.systemLoginItem = fake.item
        XCTAssertNotNil(BackgroundRefreshService.migrateLegacyAppLoginItem(paths: upgraded))
        XCTAssertEqual(fake.registers, 1)
        XCTAssertFalse(fm.fileExists(atPath: legacyPlist(paths).path))
        XCTAssertNil(BackgroundRefreshService.migrateLegacyAppLoginItem(paths: upgraded), "nothing left to move")
    }

    func testMigrationLeavesAMakeInstalledPlistAlone() throws {
        let fake = FakeItem()
        let paths = try paths(item: fake)
        try fm.createDirectory(at: paths.launchdDirectory, withIntermediateDirectories: true)
        // `make install` renders the plist against ~/.local/bin, not Set up's helpers.
        try "<plist><dict><key>Label</key><string>\(appLabel)</string><string>/Users/x/.local/bin</string></dict></plist>"
            .write(to: legacyPlist(paths), atomically: true, encoding: .utf8)
        XCTAssertNil(BackgroundRefreshService.migrateLegacyAppLoginItem(paths: paths))
        XCTAssertEqual(fake.registers, 0)
        XCTAssertTrue(fm.fileExists(atPath: legacyPlist(paths).path))
    }

    func testRemoveTurnsTheLoginItemOff() throws {
        let fake = FakeItem()
        let paths = try paths(item: fake)
        _ = BackgroundRefreshService.setUp(paths: paths, providers: ["codex"])
        _ = BackgroundRefreshService.remove(paths: paths)
        XCTAssertEqual(fake.unregisters, 1)
        XCTAssertFalse(BackgroundRefreshService.isInstalled(paths: paths))
    }
}
