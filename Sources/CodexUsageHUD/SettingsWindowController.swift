import AppKit
import SwiftUI

/// The Settings window: native toolbar tabs, a
/// remembered frame, and the system's light or dark appearance.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let title = "Usage HUD Settings"
    static let frameAutosaveName = "UsageHUDSettingsWindow.v2"
    static let defaultContentSize = NSSize(width: 640, height: 620)
    static let minContentSize = NSSize(width: 560, height: 460)

    let jobs: BackgroundJobsModel
    private let tabs: NSTabViewController
    private var hasRestoredFrame = false
    private var hasBeenShown = false

    init(state: UsageState) {
        let jobs = BackgroundJobsModel()
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        // Keep "Usage HUD Settings" as the window title on every tab.
        tabs.canPropagateSelectedChildViewControllerTitle = false
        for pane in SettingsPane.allCases {
            let host = NSHostingController(rootView: SettingsPaneView(pane: pane, state: state, jobs: jobs))
            // The window, not SwiftUI's ideal size, decides the frame, so
            // switching tabs never jumps the window around.
            host.sizingOptions = []
            let item = NSTabViewItem(viewController: host)
            item.label = pane.title
            item.identifier = pane.rawValue
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .preference
        window.title = Self.title
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.setContentSize(Self.defaultContentSize)
        window.contentMinSize = Self.minContentSize
        // No fixed appearance: the window follows System Settings › Appearance.
        window.appearance = nil

        self.jobs = jobs
        self.tabs = tabs
        super.init(window: window)
        window.delegate = self
        hasRestoredFrame = window.setFrameUsingName(Self.frameAutosaveName)
        window.setFrameAutosaveName(Self.frameAutosaveName)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show(pane: SettingsPane? = nil) {
        guard let window else { return }
        if let pane, let index = SettingsPane.allCases.firstIndex(of: pane) {
            tabs.selectedTabViewItemIndex = index
        }
        // Centre only the very first time with no saved frame; after that
        // the window opens where it was left.
        if !hasBeenShown && !hasRestoredFrame {
            window.center()
        }
        hasBeenShown = true
        jobs.reload()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Offscreen snapshot

    /// Renders every tab, light and dark, to `<dir>/settings-<tab>-<light|dark>.png`
    /// (whole window: title bar, toolbar tabs and content), then returns.
    /// Read-only: no button is pressed and nothing is installed. Hook from
    /// App.swift: `CODEX_USAGE_HUD_SETTINGS_SNAPSHOT=<dir>`.
    static func renderSnapshots(to directory: String) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let dir = URL(fileURLWithPath: NSString(string: directory).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        ProviderPreferences.ensureInitialized()
        let state = UsageState()
        state.refreshNow()
        let controller = SettingsWindowController(state: state)
        guard let window = controller.window else { return 1 }
        window.setFrameAutosaveName("")
        window.setContentSize(defaultContentSize)
        // Far outside every display: the capture never shows on screen.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()

        var written = 0
        for variant in ["light", "dark"] {
            window.appearance = NSAppearance(named: variant == "light" ? .aqua : .darkAqua)
            for (index, pane) in SettingsPane.allCases.enumerated() {
                controller.tabs.selectedTabViewItemIndex = index
                let resultMode = ProcessInfo.processInfo.environment["CODEX_USAGE_HUD_SETTINGS_SNAPSHOT_RESULT"]
                if (pane == .general || pane == .help), let resultMode, !resultMode.isEmpty {
                    let output = resultMode == "rate-limited"
                        ? "OK  codex windows: current\nWARN  claude official /usage: rate_limited · provider cooldown\nWARN  claude windows: old reading\nOK  claude statusline tap: optional integration not configured"
                        : "OK  claude windows: week 42%\nOK  codex windows: week 31%\nWARN  grok writer log: 2 errors in the last hour\nOK  com.codexusagehud.refresh: running"
                    controller.jobs.showSnapshotResult(
                        BackgroundJobsModel.diagnosticsResult(output),
                        expanded: resultMode == "1"
                    )
                }
                pump(seconds: 0.6)
                guard let frameView = window.contentView?.superview else { continue }
                frameView.layoutSubtreeIfNeeded()
                frameView.displayIfNeeded()
                guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { continue }
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else { continue }
                let out = dir.appendingPathComponent("settings-\(pane.rawValue)-\(variant).png")
                if (try? png.write(to: out)) != nil {
                    written += 1
                    FileHandle.standardError.write(Data("settings snapshot written: \(out.path)\n".utf8))
                }
            }
        }
        window.orderOut(nil)
        return written == SettingsPane.allCases.count * 2 ? 0 : 1
    }

    private static func pump(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.03))
        }
    }
}
