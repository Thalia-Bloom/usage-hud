import AppKit
import XCTest
@testable import CodexUsageHUD

final class AppShellTests: XCTestCase {
    private func freshDefaults() -> (UserDefaults, String) {
        let suite = "AppShellTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    // MARK: First run

    func testFirstRunPresentsExactlyOnce() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(FirstRun.shouldPresent(defaults: defaults, snapshotMode: false, existingInstall: false))
        XCTAssertFalse(FirstRun.shouldPresent(defaults: defaults, snapshotMode: false, existingInstall: false))
        XCTAssertTrue(defaults.bool(forKey: FirstRun.presentedKey))
    }

    func testFirstRunSkipsUpgradesAndRecordsThem() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(FirstRun.shouldPresent(defaults: defaults, snapshotMode: false, existingInstall: true))
        XCTAssertTrue(defaults.bool(forKey: FirstRun.presentedKey), "an existing install never sees it later either")
    }

    func testFirstRunNeverPresentsOrRecordsInSnapshotMode() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(FirstRun.shouldPresent(defaults: defaults, snapshotMode: true, existingInstall: false))
        XCTAssertFalse(defaults.bool(forKey: FirstRun.presentedKey))
        XCTAssertTrue(FirstRun.shouldPresent(defaults: defaults, snapshotMode: false, existingInstall: false))
    }

    func testExistingInstallMeansSetUpRanNotJustPreferences() {
        XCTAssertFalse(FirstRun.isExistingInstall(setUpDone: { false }), "1.2.0 from Downloads wrote preferences but never set up")
        XCTAssertTrue(FirstRun.isExistingInstall(setUpDone: { true }))
    }

    func testFirstRunSurvivesAMoveAndRelaunch() throws {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var setUp = false

        // Launch 1 from Downloads: fresh, then moves itself.
        XCTAssertFalse(FirstRun.noteLaunch(defaults: defaults, setUpDone: { setUp }))
        // Launch 2 from Applications: still a fresh install, so it presents
        // (and sets itself up while it does).
        let existing = FirstRun.noteLaunch(defaults: defaults, setUpDone: { setUp })
        XCTAssertFalse(existing)
        XCTAssertTrue(FirstRun.shouldPresent(defaults: defaults, snapshotMode: false, existingInstall: existing))
        setUp = true
        // Launch 3: an ordinary existing install.
        XCTAssertTrue(FirstRun.noteLaunch(defaults: defaults, setUpDone: { setUp }))
        XCTAssertFalse(FirstRun.shouldPresent(defaults: defaults, snapshotMode: false, existingInstall: true))
    }

    func testUpgradeFromAOneTwoCopyThatNeverSetUpGetsTheFirstRun() {
        let (defaults, suite) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: ProviderPreferences.connectedKey(for: "codex"))
        let existing = FirstRun.noteLaunch(defaults: defaults, setUpDone: { false })
        XCTAssertFalse(existing)
        XCTAssertTrue(FirstRun.shouldPresent(defaults: defaults, snapshotMode: false, existingInstall: existing))
    }

    func testNotchDetectionUsesTheGapBetweenAuxiliaryAreas() {
        // 14" MacBook Pro geometry: notch spans x 663...848.
        let left = NSRect(x: 0, y: 950, width: 663, height: 32)
        let right = NSRect(x: 848, y: 950, width: 664, height: 32)
        XCTAssertTrue(FirstRun.isHiddenByNotch(buttonRect: NSRect(x: 796, y: 954, width: 51, height: 22), topLeftArea: left, topRightArea: right))
        XCTAssertFalse(FirstRun.isHiddenByNotch(buttonRect: NSRect(x: 1100, y: 954, width: 30, height: 22), topLeftArea: left, topRightArea: right))
        XCTAssertFalse(FirstRun.isHiddenByNotch(buttonRect: NSRect(x: 796, y: 954, width: 51, height: 22), topLeftArea: nil, topRightArea: nil), "no notch, never hidden")
    }

    // MARK: Move to Applications

    private let home = URL(fileURLWithPath: "/Users/buyer")

    private func plan(
        _ bundle: String,
        original: String? = nil,
        environment: [String: String] = [:],
        snapshot: Bool = false,
        suppressed: Bool = false,
        writable: Bool = true
    ) -> MoveToApplications.Plan? {
        MoveToApplications.plan(
            bundleURL: URL(fileURLWithPath: bundle),
            executablePath: bundle + "/Contents/MacOS/CodexUsageHUD",
            originalBundleURL: original.map { URL(fileURLWithPath: $0) },
            home: home,
            environment: environment,
            snapshotMode: snapshot,
            suppressed: suppressed,
            systemApplicationsWritable: writable
        )
    }

    func testMoveIsNotOfferedInsideApplications() {
        XCTAssertNil(plan("/Applications/CodexUsageHUD.app"))
        XCTAssertNil(plan("/Users/buyer/Applications/CodexUsageHUD.app"))
    }

    func testMoveFromDownloadsLeavesTheOriginalSoMacOSNeverAsksAboutDownloads() throws {
        let p = try XCTUnwrap(plan("/Users/buyer/Downloads/CodexUsageHUD.app"))
        XCTAssertEqual(p.destination.path, "/Applications/CodexUsageHUD.app")
        XCTAssertEqual(p.original.path, "/Users/buyer/Downloads/CodexUsageHUD.app")
        XCTAssertFalse(MoveToApplications.informativeText(for: p).contains("Trash"))
        XCTAssertTrue(MoveToApplications.informativeText(for: p).contains("your Applications folder"))
    }

    func testMoveFallsBackToUserApplicationsWhenSystemFolderIsReadOnly() throws {
        let p = try XCTUnwrap(plan("/Users/buyer/Downloads/CodexUsageHUD.app", writable: false))
        XCTAssertEqual(p.destination.path, "/Users/buyer/Applications/CodexUsageHUD.app")
    }

    func testMoveFromDiskImageKeepsOriginal() throws {
        let p = try XCTUnwrap(plan("/Volumes/Usage HUD/CodexUsageHUD.app"))
        XCTAssertEqual(p.original.path, "/Volumes/Usage HUD/CodexUsageHUD.app")
        XCTAssertFalse(MoveToApplications.informativeText(for: p).contains("Trash"))
    }

    func testTranslocatedCopyMovesFromMirrorToApplications() throws {
        let mirror = "/private/var/folders/xx/T/AppTranslocation/ABCD/d/CodexUsageHUD.app"
        let p = try XCTUnwrap(plan(mirror, original: "/Users/buyer/Downloads/CodexUsageHUD.app"))
        XCTAssertEqual(p.source.path, mirror)
        XCTAssertEqual(p.original.path, "/Users/buyer/Downloads/CodexUsageHUD.app")
        XCTAssertEqual(p.destination.path, "/Applications/CodexUsageHUD.app")

        XCTAssertNil(plan(mirror, original: "/Applications/CodexUsageHUD.app"), "never copy a bundle onto itself")
    }

    func testMoveNeverRunsForTestsSnapshotsStateOverridesOrNonBundles() {
        let downloads = "/Users/buyer/Downloads/CodexUsageHUD.app"
        XCTAssertNil(plan(downloads, environment: ["CODEX_USAGE_HUD_STATE_DIR": "/tmp/x"]))
        XCTAssertNil(plan(downloads, environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]))
        XCTAssertNil(plan(downloads, snapshot: true))
        XCTAssertNil(plan(downloads, suppressed: true))
        XCTAssertNil(plan("/Users/buyer/src/hud/.build/release"))
        XCTAssertNotNil(plan(downloads, environment: ["CODEX_USAGE_HUD_STATE_DIR": ""]))
    }

    // MARK: Tooltip and VoiceOver text

    func testPercentNeverLiesAtTheEdges() {
        XCTAssertEqual(StatusItemText.percent(72), "72%")
        XCTAssertEqual(StatusItemText.percent(0), "0%")
        XCTAssertEqual(StatusItemText.percent(0.3), "<1%")
        XCTAssertEqual(StatusItemText.percent(99.6), "99%")
        XCTAssertEqual(StatusItemText.percent(100), "100%")
        XCTAssertEqual(StatusItemText.percent(.nan), "--")
    }

    func testLaneSummaryUsesPlainWords() {
        XCTAssertEqual(StatusItemText.laneSummary(.init(name: "Claude", weekUsed: 28, sessionUsed: 10, mode: "green")), "Claude 28% of week")
        XCTAssertEqual(StatusItemText.laneSummary(.init(name: "Claude", weekUsed: 62, sessionUsed: 10, mode: "yellow")), "Claude 62% of week \u{00B7} running hot")
        XCTAssertEqual(StatusItemText.laneSummary(.init(name: "Codex", weekUsed: 40, sessionUsed: 85, mode: "orange")), "Codex 40% of week \u{00B7} 5-hour 85% \u{00B7} running low")
        XCTAssertEqual(StatusItemText.laneSummary(.init(name: "Gemini", weekUsed: nil, sessionUsed: 30, mode: "green")), "Gemini 30% of 5-hour window")
        XCTAssertEqual(StatusItemText.laneSummary(.init(name: "Grok", weekUsed: nil, sessionUsed: nil, mode: "unknown")), "Grok no reading yet")
        XCTAssertEqual(StatusItemText.laneSummary(.init(name: "Local Models", weekUsed: nil, sessionUsed: nil, mode: "local", tokensToday: 1_234_567)), "Local Models 1.2M tokens today")
        XCTAssertEqual(StatusItemText.plainStatus("red"), "nearly out")
        XCTAssertEqual(StatusItemText.plainStatus("freeze"), "spent until reset")
    }

    func testTooltipHasNoInternalModeWordsOrDoubledLeft() {
        let readings = ["green", "yellow", "orange", "red", "freeze", "unknown"].map {
            StatusLaneReading(name: "Claude", weekUsed: 72, sessionUsed: nil, mode: $0)
        } + [StatusLaneReading(name: "Grok", weekUsed: nil, sessionUsed: nil, mode: "unknown")]
        let text = StatusItemText.tooltip(readings) + "\n" + StatusItemText.accessibilityValue(readings)
        for word in ["GO", "WATCH", "SLOW", "STOP", "FREEZE", "WAIT"] {
            XCTAssertNil(text.range(of: "\\b\(word)\\b", options: .regularExpression), "tooltip leaked \(word)")
        }
        XCTAssertFalse(text.contains("left left"))
        XCTAssertTrue(text.hasPrefix("Usage HUD\n"))
        XCTAssertEqual(StatusItemText.tooltip([]).components(separatedBy: "\n").count, 3)
    }

    func testAccessibilityValueReadsEachLane() {
        let value = StatusItemText.accessibilityValue([
            StatusLaneReading(name: "Claude", weekUsed: 4, sessionUsed: nil, mode: "green"),
            StatusLaneReading(name: "Codex", weekUsed: 89, sessionUsed: nil, mode: "orange"),
        ])
        XCTAssertEqual(value, "Claude 4% of week; Codex 89% of week, running low")
        XCTAssertEqual(StatusItemText.accessibilityValue([]), "No tools shown yet")
    }

    func testReadingsPutFableRightAfterClaude() throws {
        let decoder = JSONDecoder()
        let claude = try decoder.decode(UsageSnapshot.self, from: Data(#"{"provider":"claude","week":{"usedPct":30},"weekFable":{"usedPct":85}}"#.utf8))
        let codex = try decoder.decode(UsageSnapshot.self, from: Data(#"{"provider":"codex","currentSession":{"usedPct":12}}"#.utf8))
        let readings = StatusItemText.readings(providers: ["claude", "codex", "grok"], snapshots: [claude, codex], budgets: [:])
        XCTAssertEqual(readings.map(\.name), ["Claude", "Fable", "Codex", "Grok"])
        XCTAssertEqual(readings[1].weekUsed, 85)
        XCTAssertEqual(readings[1].mode, "orange")
        XCTAssertEqual(readings[2].weekUsed ?? readings[2].sessionUsed, 12, "session stands in when there is no weekly reading")
        XCTAssertFalse(readings[3].isConnected)
        XCTAssertEqual(readings[3].mode, "unknown")
    }

    // MARK: Glyph

    func testGaugeFillSeparatesLowPercentages() {
        let oneX = [0.0, 20, 39].map { UsageStatusIcon.fillWidth(left: $0, pixelsPerPoint: 1) }
        XCTAssertEqual(Set(oneX).count, 3, "0, 20 and 39% left must not look the same at 1x: \(oneX)")
        XCTAssertEqual(UsageStatusIcon.fillWidth(left: 0, pixelsPerPoint: 2), 0.5, "a known 0% keeps a one-pixel sliver")
        XCTAssertEqual(UsageStatusIcon.fillWidth(left: 140, pixelsPerPoint: 2), UsageStatusIcon.gaugeWidth - 4)
        XCTAssertEqual(UsageStatusIcon.text(left: 47), "47% left", "the menu bar number always says left")
    }

    func testGaugeStaysTemplateWhileCalm() {
        XCTAssertTrue(UsageStatusIcon.image(left: 53, tone: .calm).isTemplate)
        XCTAssertTrue(UsageStatusIcon.image(left: nil, tone: .spent).isTemplate, "no reading has nothing to color")
        XCTAssertFalse(UsageStatusIcon.image(left: 8, tone: .spent).isTemplate)
        let now = Date()
        let pace = LanePace(used: 4, elapsed: 2, windowTag: "wk", status: "ON PACE", statusColor: .gray, barColor: .gray, valueColor: .gray, sub: nil)
        XCTAssertEqual(UsageStatusIcon.tone(pace, backAt: now.addingTimeInterval(-600), now: now), .back)
        XCTAssertEqual(UsageStatusIcon.tone(pace, backAt: now.addingTimeInterval(-7200), now: now), .calm, "green only for the first hour")
    }

    // MARK: Clicks, keys, motion

    func testRightOrControlClickOpensMenu() {
        XCTAssertTrue(StatusClick.opensMenu(type: .rightMouseUp, modifiers: []))
        XCTAssertTrue(StatusClick.opensMenu(type: .leftMouseUp, modifiers: [.control]))
        XCTAssertFalse(StatusClick.opensMenu(type: .leftMouseUp, modifiers: []))
        XCTAssertFalse(StatusClick.opensMenu(type: .leftMouseUp, modifiers: [.command]))
    }

    func testPanelCloseKeys() {
        XCTAssertTrue(PanelKeys.closes(keyCode: 53, modifiers: [], characters: "\u{1B}"))
        XCTAssertFalse(PanelKeys.closes(keyCode: 53, modifiers: [.command], characters: "\u{1B}"))
        XCTAssertTrue(PanelKeys.closes(keyCode: 13, modifiers: [.command], characters: "w"))
        XCTAssertTrue(PanelKeys.closes(keyCode: 47, modifiers: [.command], characters: "."))
        XCTAssertFalse(PanelKeys.closes(keyCode: 13, modifiers: [], characters: "w"))
        XCTAssertFalse(PanelKeys.closes(keyCode: 13, modifiers: [.command, .shift], characters: "w"))
    }

    func testReduceMotionDropsTheSlide() {
        XCTAssertEqual(PanelMotion.slideOffset(reduceMotion: true), 0)
        XCTAssertGreaterThan(PanelMotion.slideOffset(reduceMotion: false), 0)
        XCTAssertEqual(PanelMotion.resizeDuration(reduceMotion: true), 0)
        XCTAssertLessThan(PanelMotion.showDuration(reduceMotion: true), PanelMotion.showDuration(reduceMotion: false))
    }

    // MARK: Menus and About

    func testStatusMenuOrderAndShortcuts() {
        let entries = AppMenu.statusEntries
        XCTAssertEqual(entries.map(\.title), [
            "Open Usage HUD", "Refresh", "", "Settings\u{2026}", "Check for Updates\u{2026}",
            "Help and Support", "About Usage HUD", "", "Quit Usage HUD",
        ])
        XCTAssertEqual(entries.first { $0.command == .settings }?.keyEquivalent, ",")
        XCTAssertEqual(entries.first { $0.command == .quit }?.keyEquivalent, "q")
        XCTAssertEqual(Notification.Name.usageHUDCheckForUpdates.rawValue, "usageHUDCheckForUpdates")
    }

    @MainActor
    func testStatusMenuItemsAreWiredAndCheckForUpdatesPosts() {
        let actions = AppMenuActions()
        let menu = AppMenu.statusMenu(actions: actions)
        XCTAssertEqual(menu.items.count, AppMenu.statusEntries.count)
        for item in menu.items where !item.isSeparatorItem {
            XCTAssertTrue(item.target === actions, "\(item.title) needs a live target")
            XCTAssertNotNil(item.action)
        }
        let posted = expectation(forNotification: .usageHUDCheckForUpdates, object: nil)
        let check = menu.items.first { $0.title == "Check for Updates\u{2026}" }
        XCTAssertNotNil(check)
        _ = check.map { NSApplication.shared.sendAction($0.action!, to: $0.target, from: $0) }
        wait(for: [posted], timeout: 1)
    }

    @MainActor
    func testMainMenuRoutesEditingAndCloseShortcuts() throws {
        _ = NSApplication.shared
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        AppMenu.installMainMenu(actions: AppMenuActions())
        let items = try XCTUnwrap(NSApp.mainMenu).items.flatMap { $0.submenu?.items ?? [] }
        func item(_ action: String) -> NSMenuItem? { items.first { $0.action == NSSelectorFromString(action) } }
        XCTAssertEqual(item("copy:")?.keyEquivalent, "c")
        XCTAssertEqual(item("paste:")?.keyEquivalent, "v")
        XCTAssertEqual(item("cut:")?.keyEquivalent, "x")
        XCTAssertEqual(item("selectAll:")?.keyEquivalent, "a")
        XCTAssertEqual(item("undo:")?.keyEquivalent, "z")
        XCTAssertEqual(item("redo:")?.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(item("performClose:")?.keyEquivalent, "w")
        XCTAssertEqual(item("terminate:")?.keyEquivalent, "q")
        XCTAssertEqual(item("openSettingsAction:")?.keyEquivalent, ",")
    }

    func testAboutCreditsNameTheMakerAndLinkTheSite() {
        let credits = AppMenu.aboutCredits()
        XCTAssertTrue(credits.string.contains("Free. Made by Thalia Bloom."))
        XCTAssertTrue(credits.string.contains("hud.thaliabloom.com"))
        var linked: URL?
        credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) { value, _, _ in
            if let url = value as? URL { linked = url }
        }
        XCTAssertEqual(linked?.host, "hud.thaliabloom.com")
    }
}
