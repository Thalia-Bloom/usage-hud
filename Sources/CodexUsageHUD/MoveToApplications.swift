import AppKit
import Darwin

/// Offers once per launch to move a copy that runs from Downloads, a disk
/// image, or Gatekeeper's AppTranslocation mirror into Applications. Set up
/// refuses to write login items for those locations, so without the move a
/// new user hits a dead end.
enum MoveToApplications {
    static let suppressKey = "usageHUD.moveToApplications.suppressed"

    struct Plan: Equatable {
        /// The running bundle (for a translocated copy, the read-only mirror).
        var source: URL
        /// `<Applications>/<name>.app`.
        var destination: URL
        /// The copy the user sees in Finder.
        var original: URL
    }

    /// Pure decision: nil means "do not offer".
    static func plan(
        bundleURL: URL,
        executablePath: String,
        originalBundleURL: URL?,
        home: URL,
        environment: [String: String],
        snapshotMode: Bool,
        suppressed: Bool,
        systemApplicationsWritable: Bool
    ) -> Plan? {
        guard !snapshotMode, !suppressed else { return nil }
        if let stateDir = environment["CODEX_USAGE_HUD_STATE_DIR"], !stateDir.isEmpty { return nil }
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil { return nil }
        // `swift run` and test binaries are not bundles; nothing to move.
        guard bundleURL.pathExtension == "app" else { return nil }
        guard BackgroundRefreshService.installLocationIssue(appExecutable: executablePath, home: home) != nil else { return nil }

        let original = (originalBundleURL ?? bundleURL).standardizedFileURL
        let applications = systemApplicationsWritable
            ? URL(fileURLWithPath: "/Applications", isDirectory: true)
            : home.appendingPathComponent("Applications", isDirectory: true)
        let destination = applications.appendingPathComponent(original.lastPathComponent).standardizedFileURL
        // A translocated copy that already lives in Applications only needs
        // reopening from Finder; copying it onto itself would destroy it.
        guard destination.path != original.path else { return nil }

        // The original stays where it is. Trashing a copy in Downloads made
        // macOS ask "Usage HUD would like to access files in your Downloads
        // folder" in the middle of the move (clean macOS 26 VM, 2026-10-03).
        return Plan(
            source: bundleURL.standardizedFileURL,
            destination: destination,
            original: original
        )
    }

    static func informativeText(for plan: Plan) -> String {
        let folder = plan.destination.deletingLastPathComponent().path == "/Applications"
            ? "your Applications folder"
            : "the Applications folder in your home folder"
        return "Usage HUD runs from \(folder), so it can start when you log in. It copies itself there and reopens."
    }

    // MARK: - Live path

    /// Shows the alert when this copy should move. Returns true when the app
    /// is about to quit and reopen from Applications.
    @MainActor
    static func offerIfNeeded(defaults: UserDefaults = .standard) -> Bool {
        let bundleURL = Bundle.main.bundleURL
        let fileManager = FileManager.default
        guard let plan = plan(
            bundleURL: bundleURL,
            executablePath: Bundle.main.executablePath ?? CommandLine.arguments.first ?? "",
            originalBundleURL: translocatedOriginal(of: bundleURL),
            home: fileManager.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment,
            snapshotMode: SnapshotMode.enabled,
            suppressed: defaults.bool(forKey: suppressKey),
            systemApplicationsWritable: fileManager.isWritableFile(atPath: "/Applications")
        ) else { return false }

        AppMenu.bringAppForward()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Move Usage HUD to Applications?"
        alert.informativeText = informativeText(for: plan)
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            defaults.set(true, forKey: suppressKey)
        }
        guard response == .alertFirstButtonReturn else { return false }

        switch perform(plan) {
        case .moved(let destination):
            relaunch(from: destination)
            NSApp.terminate(nil)
            return true
        case .failed(let reason):
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = "Usage HUD couldn't move itself"
            failure.informativeText = "\(reason) Drag Usage HUD into your Applications folder in Finder, then open it from there."
            failure.addButton(withTitle: "OK")
            failure.runModal()
            return false
        }
    }

    enum Outcome: Equatable {
        case moved(URL)
        case failed(String)
    }

    @MainActor
    static func perform(_ plan: Plan, fileManager: FileManager = .default) -> Outcome {
        let applications = plan.destination.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: applications, withIntermediateDirectories: true)
        } catch {
            return .failed("It could not open \(applications.path).")
        }
        if fileManager.fileExists(atPath: plan.destination.path) {
            // An older copy goes to the Trash, never straight to deletion.
            do {
                try fileManager.trashItem(at: plan.destination, resultingItemURL: nil)
            } catch {
                return .failed("An older copy in \(applications.path) could not be replaced.")
            }
        }
        guard run("/usr/bin/ditto", [plan.source.path, plan.destination.path]) == 0,
              fileManager.fileExists(atPath: plan.destination.appendingPathComponent("Contents/MacOS").path)
        else {
            return .failed("Copying to \(applications.path) failed.")
        }
        // Gatekeeper already cleared this copy to run. Dropping the
        // quarantine flag stops macOS from translocating the new copy again.
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", plan.destination.path])

        guard run("/usr/bin/codesign", ["--verify", "--deep", plan.destination.path]) == 0 else {
            return .failed("The copy in \(applications.path) didn’t pass macOS’s signature check.")
        }
        return .moved(plan.destination)
    }

    /// Reopens the moved copy once this process has exited, so the new
    /// copy's single-instance guard does not hand control back to us.
    private static func relaunch(from destination: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = #"while /bin/kill -0 "$1" >/dev/null 2>&1; do /bin/sleep 0.2; done; /usr/bin/open -n "$2""#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(pid), destination.path]
        try? process.run()
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// For a Gatekeeper-translocated bundle, the path the user actually
    /// double-clicked. Uses the Security framework's lookup when present.
    static func translocatedOriginal(of url: URL) -> URL? {
        guard url.path.contains("/AppTranslocation/"),
              let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY)
        else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        typealias Lookup = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let lookup = unsafeBitCast(symbol, to: Lookup.self)
        return lookup(url as CFURL, nil)?.takeRetainedValue() as URL?
    }
}
