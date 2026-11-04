import AppKit
import Foundation
import os
import Sparkle

/// Sparkle 2 auto-updates for the shipped app.
///
/// Settings come from Resources/Info.plist (SUFeedURL, SUPublicEDKey,
/// SUEnableAutomaticChecks, SUScheduledCheckInterval, SUAutomaticallyUpdate),
/// so Sparkle checks once a day and asks before installing; its update alert
/// carries the "install automatically" choice. Nothing here overrides those
/// defaults at runtime (Sparkle's API expectations).
///
/// The updater stays off (inert) in snapshot and probe modes, under tests,
/// when the executable is not inside a .app bundle (`swift run`, `.build`),
/// when the bundle lacks a feed URL or public key, and when
/// CODEX_USAGE_HUD_DISABLE_UPDATES=1.
@MainActor
final class UpdateController: NSObject {
    static let shared = UpdateController()

    /// Posted by the "Check for Updates…" menu item. AppMenu.swift declares the
    /// same name as `Notification.Name.usageHUDCheckForUpdates`; it is spelled
    /// out here so the two files never declare the same static.
    nonisolated static let checkForUpdatesNotification = Notification.Name("usageHUDCheckForUpdates")

    enum Availability: Equatable {
        case enabled
        case disabled(String)
    }

    /// Environment keys that turn the app into a one-shot renderer or probe.
    nonisolated static let oneShotModeKeys = [
        "CODEX_USAGE_HUD_SNAPSHOT",
        "CODEX_USAGE_HUD_ACTIVITY_SNAPSHOT",
        "CODEX_USAGE_HUD_GLYPH_SNAPSHOT",
        "CODEX_USAGE_HUD_SPEND_PROBE",
    ]

    nonisolated static let disableKey = "CODEX_USAGE_HUD_DISABLE_UPDATES"

    private let logger = Logger(subsystem: "com.codexusagehud.app", category: "updates")
    private var updaterController: SPUStandardUpdaterController?
    private var checkObserver: NSObjectProtocol?

    /// True once Sparkle's updater has started.
    var isActive: Bool { updaterController != nil }

    private override init() {
        super.init()
    }

    /// Decides whether Sparkle may run in this process. Pure, so tests can
    /// cover every branch without starting an updater.
    nonisolated static func availability(
        environment: [String: String],
        bundleURL: URL,
        infoDictionary: [String: Any]?,
        isRunningTests: Bool
    ) -> Availability {
        if environment[disableKey] == "1" {
            return .disabled("\(disableKey)=1")
        }
        if let key = oneShotModeKeys.first(where: { !(environment[$0] ?? "").isEmpty }) {
            return .disabled("\(key) is set")
        }
        if isRunningTests {
            return .disabled("running under tests")
        }
        guard bundleURL.pathExtension.lowercased() == "app" else {
            return .disabled("not running from a .app bundle")
        }
        let feed = (infoDictionary?["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let url = URL(string: feed), url.scheme != nil else {
            return .disabled("Info.plist has no SUFeedURL")
        }
        let key = (infoDictionary?["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !key.isEmpty else {
            return .disabled("Info.plist has no SUPublicEDKey")
        }
        return .enabled
    }

    nonisolated static var isRunningTests: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil || env["XCTestSessionIdentifier"] != nil {
            return true
        }
        return NSClassFromString("XCTestCase") != nil
    }

    /// Starts Sparkle once. Call from applicationDidFinishLaunching.
    func start() {
        guard updaterController == nil else { return }
        let availability = Self.availability(
            environment: ProcessInfo.processInfo.environment,
            bundleURL: Bundle.main.bundleURL,
            infoDictionary: Bundle.main.infoDictionary,
            isRunningTests: Self.isRunningTests
        )
        guard availability == .enabled else {
            if case .disabled(let reason) = availability {
                logger.notice("updates off: \(reason, privacy: .public)")
            }
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        do {
            // Start through SPUUpdater so a setup error lands in the log
            // instead of an alert at login.
            try controller.updater.start()
        } catch {
            logger.error("updater failed to start: \(error.localizedDescription, privacy: .public)")
            return
        }
        updaterController = controller
        checkObserver = NotificationCenter.default.addObserver(
            forName: Self.checkForUpdatesNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in UpdateController.shared.checkForUpdates() }
        }
        let feed = controller.updater.feedURL?.absoluteString ?? "none"
        logger.notice("updater started; feed \(feed, privacy: .public); automatic checks \(controller.updater.automaticallyChecksForUpdates, privacy: .public)")
    }

    /// User-initiated check ("Check for Updates…"). A no-op while inert.
    func checkForUpdates() {
        guard let updaterController else {
            logger.notice("check for updates ignored: updater is off")
            return
        }
        // Menu-bar app: bring Sparkle's window to the front of other apps.
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(nil)
    }
}

extension UpdateController: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        let build = item.versionString
        Logger(subsystem: "com.codexusagehud.app", category: "updates")
            .notice("update available: \(version, privacy: .public) (build \(build, privacy: .public))")
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        Logger(subsystem: "com.codexusagehud.app", category: "updates")
            .notice("no update: \(error.localizedDescription, privacy: .public)")
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        // Sparkle also aborts with SUNoUpdateError; updaterDidNotFindUpdate logged that.
        let nsError = error as NSError
        if nsError.domain == SUSparkleErrorDomain, nsError.code == Int(SUError.noUpdateError.rawValue) { return }
        Logger(subsystem: "com.codexusagehud.app", category: "updates")
            .error("update check aborted: \(error.localizedDescription, privacy: .public)")
    }
}

extension UpdateController: SPUStandardUserDriverDelegate {
    /// Menu-bar (dockless) app: tells Sparkle we accept its gentle scheduled
    /// reminders, so a background check never steals focus mid-task. A
    /// scheduled alert still shows in front right after launch.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
