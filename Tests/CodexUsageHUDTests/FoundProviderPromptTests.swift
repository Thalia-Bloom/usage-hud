import XCTest
@testable import CodexUsageHUD

/// The "Found X — add it?" prompt is generic across every `ProviderCatalog`
/// entry: a lane only needs a detection rule in `ToolDetection` to get it.
final class FoundProviderPromptTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "UsageHUDTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// Preferences already initialized (as `applyDetection` would leave
    /// them) with `provider` currently off — the realistic starting point
    /// for a "found but hidden" prompt, rather than an untouched suite where
    /// `isShown` still falls back to its own default.
    private func markPreviouslyOff(_ provider: String, defaults: UserDefaults) {
        defaults.set(false, forKey: ProviderPreferences.connectedKey(for: provider))
        defaults.set(false, forKey: ProviderPreferences.shownKey(for: provider))
    }

    /// Grok counts as found when `~/.grok/auth.json` exists.
    private func fakeGrokProbe(signedIn: Bool = false, home: URL) -> ToolDetection.Probe {
        ToolDetection.Probe(
            home: home,
            fileExists: { $0.path == home.appendingPathComponent(".grok/auth.json").path && signedIn },
            isExecutable: { _ in false },
            keychainItemExists: { _ in false },
            nodeAvailable: true,
            python3Available: true
        )
    }

    func testDetectedProviderNotShownAppearsInFoundButNotShown() {
        let defaults = makeDefaults()
        let home = URL(fileURLWithPath: "/tmp/nonexistent-home-\(UUID().uuidString)")
        markPreviouslyOff("grok", defaults: defaults)
        let summary = ToolDetection.detect(probe: fakeGrokProbe(signedIn: true, home: home))

        let found = ProviderPreferences.foundButNotShown(defaults: defaults, detect: { summary })
        XCTAssertTrue(found.contains { $0.id == "grok" })
    }

    func testAlreadyShownProviderNeverPrompts() {
        let defaults = makeDefaults()
        let home = URL(fileURLWithPath: "/tmp/nonexistent-home-\(UUID().uuidString)")
        defaults.set(true, forKey: ProviderPreferences.shownKey(for: "grok"))
        let summary = ToolDetection.detect(probe: fakeGrokProbe(signedIn: true, home: home))

        let found = ProviderPreferences.foundButNotShown(defaults: defaults, detect: { summary })
        XCTAssertFalse(found.contains { $0.id == "grok" })
    }

    func testAddingMarksItShownAndConnectedAndClearsThePrompt() {
        let defaults = makeDefaults()
        let home = URL(fileURLWithPath: "/tmp/nonexistent-home-\(UUID().uuidString)")
        markPreviouslyOff("grok", defaults: defaults)
        let summary = ToolDetection.detect(probe: fakeGrokProbe(signedIn: true, home: home))
        XCTAssertTrue(ProviderPreferences.foundButNotShown(defaults: defaults, detect: { summary }).contains { $0.id == "grok" })

        ProviderPreferences.addDetectedProvider("grok", defaults: defaults)

        XCTAssertTrue(ProviderPreferences.isShown("grok", defaults: defaults))
        XCTAssertTrue(ProviderPreferences.isConnected("grok", defaults: defaults))
        XCTAssertFalse(ProviderPreferences.foundButNotShown(defaults: defaults, detect: { summary }).contains { $0.id == "grok" })
    }

    func testNotNowDismissesWithoutEnablingAndPersistsAcrossLaunches() {
        let defaults = makeDefaults()
        let home = URL(fileURLWithPath: "/tmp/nonexistent-home-\(UUID().uuidString)")
        markPreviouslyOff("grok", defaults: defaults)
        let summary = ToolDetection.detect(probe: fakeGrokProbe(signedIn: true, home: home))
        XCTAssertTrue(ProviderPreferences.foundButNotShown(defaults: defaults, detect: { summary }).contains { $0.id == "grok" })

        ProviderPreferences.dismissFoundPrompt("grok", defaults: defaults)

        XCTAssertFalse(ProviderPreferences.isShown("grok", defaults: defaults))
        // Simulate a relaunch: detection runs again, the dismissal must still hold.
        XCTAssertFalse(ProviderPreferences.foundButNotShown(defaults: defaults, detect: { summary }).contains { $0.id == "grok" })
    }

    func testUndetectedProviderNeverPrompts() {
        let defaults = makeDefaults()
        let home = URL(fileURLWithPath: "/tmp/nonexistent-home-\(UUID().uuidString)")
        markPreviouslyOff("grok", defaults: defaults)
        let summary = ToolDetection.detect(probe: fakeGrokProbe(home: home))
        XCTAssertFalse(ProviderPreferences.foundButNotShown(defaults: defaults, detect: { summary }).contains { $0.id == "grok" })
    }

}
