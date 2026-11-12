import AppKit

/// Set up loads `com.codexusagehud.app` with `RunAtLoad`, which launchd will
/// happily boot again while the app is already running. This guard makes a
/// second launch (from that plist, Finder, or a stray double-click) a no-op:
/// it hands focus to the already-running instance and quits instead of
/// putting up a second menu-bar icon.
enum SingleInstanceGuard {
    static func activateExistingInstanceIfRunning(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        currentPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        runningApplications: (String) -> [NSRunningApplication] = { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
    ) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
        let others = runningApplications(bundleIdentifier).filter { $0.processIdentifier != currentPID }
        guard let existing = others.first else { return false }
        existing.activate(options: [])
        return true
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = UsageState()
    private var panelController: UsagePanelController!
    private var statusBar: StatusBarController!
    private var settingsController: SettingsWindowController!
    private var settingsObserver: NSObjectProtocol?
    private var activityController: ActivityWindowController!
    private var activityObserver: NSObjectProtocol?
    private let menuActions = AppMenuActions()
    private let firstRunCallout = FirstRunCallout()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read before ProviderPreferences.ensureInitialized writes anything.
        let existingInstall = FirstRun.noteLaunch()

        panelController = UsagePanelController(state: state)
        menuActions.openPanel = { [weak self] in
            guard let self else { return }
            self.panelController.show(anchor: self.statusBar.item)
        }
        menuActions.refresh = { [weak self] in self?.state.forceBudgetRefresh() }
        menuActions.canRefresh = { [weak self] in
            guard let self else { return false }
            return !self.state.isManualRefreshing && !self.state.setupBusy
        }
        AppMenu.installMainMenu(actions: menuActions)
        statusBar = StatusBarController(panelController: panelController, state: state, menuActions: menuActions)
        settingsController = SettingsWindowController(state: state)
        activityController = ActivityWindowController()
        activityObserver = NotificationCenter.default.addObserver(
            forName: .usageHUDOpenActivity, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.activityController.show() }
        }
        if ProcessInfo.processInfo.environment["CODEX_USAGE_HUD_OPEN_ACTIVITY"] == "1" {
            activityController.show()
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .usageHUDOpenSettings,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let pane = (note.userInfo?["pane"] as? String).flatMap(SettingsPane.init(rawValue:))
            Task { @MainActor in
                // Settings is a normal window; the floating panel must not sit over it.
                self?.panelController.hide()
                self?.settingsController.show(pane: pane)
            }
        }

        ProviderPreferences.ensureInitialized()
        state.onSnapshotsChange = { [weak self] snapshots in
            ComeBack.shared.observe(snapshots)
            self?.statusBar.updateIcon(snapshots: snapshots)
            self?.state.resetPings.process(snapshots)
        }
        state.start()
        // Own timer, off the main thread; stands down while the claude-writer
        // LaunchAgent owns the Claude lane.
        ClaudeNativeUsageService.shared.start()
        // After an update, re-copy helpers and reload jobs if they're stale.
        BackgroundRefreshService.refreshInstalledHelpersIfStaleInBackground()
        // Sparkle: daily check, and the menu's Check for Updates….
        UpdateController.shared.start()

        // After the run loop starts, so the alert and the status item exist.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if MoveToApplications.offerIfNeeded() { return }
            let forced = ProcessInfo.processInfo.environment["CODEX_USAGE_HUD_FORCE_FIRST_RUN"] == "1"
            if forced || FirstRun.shouldPresent(defaults: .standard, snapshotMode: SnapshotMode.enabled, existingInstall: existingInstall) {
                // Give the menu bar a moment to place the new item.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.presentFirstRun()
                    self?.state.runFirstRunSetupIfReady()
                }
            }
        }
    }

    /// Opens the panel under the menu-bar item, pushed down to make room for
    /// a callout that points at the item. The panel glides up into place
    /// when the callout goes.
    private func presentFirstRun(attempt: Int = 0) {
        guard let anchor = statusBar.buttonScreenRect else {
            guard attempt < 20 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.presentFirstRun(attempt: attempt + 1)
            }
            return
        }
        // On a full menu bar the camera notch can cover the new item; say so
        // instead of pointing at an empty notch.
        let screen = statusBar.item.button?.window?.screen
        let hidden = FirstRun.isHiddenByNotch(
            buttonRect: anchor,
            topLeftArea: screen?.auxiliaryTopLeftArea,
            topRightArea: screen?.auxiliaryTopRightArea
        )
        let text = hidden ? FirstRun.notchCalloutText : FirstRun.calloutText
        panelController.show(anchor: statusBar.item, topGap: FirstRunCallout.reservedHeight(text: text))
        firstRunCallout.show(below: anchor, text: text) { [weak self] in
            self?.panelController.closeTopGap()
        }
    }

    /// Opening the app again from Finder or Launchpad shows the panel
    /// instead of doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { panelController.show(anchor: statusBar.item) }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        if let activityObserver { NotificationCenter.default.removeObserver(activityObserver) }
    }
}
