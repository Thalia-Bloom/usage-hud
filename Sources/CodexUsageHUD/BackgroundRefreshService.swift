import Foundation
import Darwin
import CryptoKit

/// Copies bundled helpers, renders LaunchAgent plists, and (on a real Mac,
/// with no directory overrides) bootstraps them. Tests and this slice set
/// `CODEX_USAGE_HUD_LAUNCHD_DIR` / `CODEX_USAGE_HUD_SUPPORT_DIR` so nothing
/// touches ~/Library/LaunchAgents.
enum BackgroundRefreshService {
    struct Paths {
        var supportDirectory: URL
        var launchdDirectory: URL
        var bundledBinDirectory: URL?
        var templateDirectory: URL?
        var home: URL
        var stateDirectory: URL
        var appExecutable: String
        var invokeLaunchctl: Bool
        var nodeAvailable: Bool
        var pythonAvailable: Bool
        /// In-app Codex fallback for Set up scoring (nil in tests).
        var codexSessionsRoot: URL? = nil
        /// In-app Claude reader (nil in tests, so no test reaches the
        /// Keychain or the network).
        var claudeNative: ((ClaudeNativeTrigger) -> ClaudeNativeRunReport)? = nil
        /// Build number recorded in the install stamp (helper refresh on update).
        var buildNumber: String = BackgroundRefreshService.currentBuildNumber
        /// The app's own login item through macOS (shows as Usage HUD). Nil
        /// in tests and with override dirs: then it is a plist in
        /// `launchdDirectory`, as before.
        var systemLoginItem: SystemLoginItem? = nil

        static func resolved(
            env: [String: String] = ProcessInfo.processInfo.environment,
            bundle: Bundle = .main
        ) -> Paths {
            let overrideSet = env["CODEX_USAGE_HUD_LAUNCHD_DIR"] != nil || env["CODEX_USAGE_HUD_SUPPORT_DIR"] != nil
            let executable = Bundle.main.executableURL?.path
                ?? UsagePaths.home.appendingPathComponent("Applications/CodexUsageHUD.app/Contents/MacOS/CodexUsageHUD").path
            return Paths(
                supportDirectory: UsagePaths.supportDirectory,
                launchdDirectory: UsagePaths.launchdDirectory,
                bundledBinDirectory: BundledHelpers.bundledBinDirectory(bundle: bundle),
                templateDirectory: BundledHelpers.bundledLaunchdDirectory(bundle: bundle),
                home: UsagePaths.home,
                stateDirectory: UsagePaths.stateDirectory,
                appExecutable: executable,
                invokeLaunchctl: !overrideSet,
                nodeAvailable: RuntimeDependencies.nodeAvailable,
                pythonAvailable: RuntimeDependencies.python3Available,
                codexSessionsRoot: UsagePaths.isIsolatedStateDir ? nil : UsagePaths.home.appendingPathComponent(".codex/sessions"),
                claudeNative: { ClaudeNativeUsageService.shared.run(trigger: $0) },
                systemLoginItem: BackgroundRefreshService.defaultSystemLoginItem(env: env)
            )
        }
    }

    struct AgentSpec {
        var label: String
        /// The detected provider id this writer serves, or nil for core
        /// agents (the app itself, the refresh loop) that install regardless
        /// of what tools were detected.
        var provider: String?
        var needsNode: Bool
        var needsPython: Bool
    }

    static let appAgentLabel = "com.codexusagehud.app"

    static let agents: [AgentSpec] = [
        AgentSpec(label: "com.codexusagehud.app", provider: nil, needsNode: false, needsPython: false),
        AgentSpec(label: "com.codexusagehud.codex-writer", provider: "codex", needsNode: true, needsPython: false),
        AgentSpec(label: "com.codexusagehud.claude-writer", provider: "claude", needsNode: true, needsPython: true),
        AgentSpec(label: "com.codexusagehud.grok-writer", provider: "grok", needsNode: true, needsPython: false),
        AgentSpec(label: "com.codexusagehud.refresh", provider: nil, needsNode: true, needsPython: false),
    ]

    struct Report {
        var lines: [String] = []
        /// Plain-words reason Set up could not run at all (wrong location,
        /// damaged copy). Nil when it ran, even if some jobs were skipped.
        var blocker: String? = nil
        var text: String { lines.joined(separator: "\n") }
    }

    struct SetupOutcome {
        var report: Report
        var lanes: [LaneSetupResult]
        var hasData: Bool
        /// Set when Set up stopped before installing anything; the card shows
        /// this instead of per-lane results it never collected.
        var blocker: String? = nil
    }

    static let damagedCopyMessage = "This copy of Usage HUD is missing files. Download it again from hud.thaliabloom.com."

    static var currentBuildNumber: String {
        let bundled = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let bundled, !bundled.isEmpty { return bundled }
        return AppInfo.buildNumber
    }

    /// True when any of the app's core LaunchAgent plists are already in the
    /// launchd directory (usually `~/Library/LaunchAgents`).
    /// Only the launchd directory matters here, so the default skips
    /// `Paths.resolved()` and its Node/Python probes (one of which spawns
    /// `xcode-select`); the in-app Claude reader asks this every minute.
    ///
    /// The app's own login item does not count: "Open at login" turns it on
    /// without running Set up, and Set up may run with it off. On a Mac
    /// without Node.js, Set up installs no job at all, so its stamp (or the
    /// helpers it copied, for Set ups older than the stamp) is the proof.
    static func isInstalled(paths: Paths? = nil, fileManager: FileManager = .default) -> Bool {
        let launchdDirectory = paths?.launchdDirectory ?? UsagePaths.launchdDirectory
        let supportDirectory = paths?.supportDirectory ?? UsagePaths.supportDirectory
        func plistExists(_ label: String) -> Bool {
            fileManager.fileExists(atPath: launchdDirectory.appendingPathComponent("\(label).plist").path)
        }
        if agents.contains(where: { $0.label != appAgentLabel && plistExists($0.label) }) { return true }
        return fileManager.fileExists(atPath: supportDirectory.appendingPathComponent(stampFilename).path)
            || fileManager.fileExists(atPath: supportDirectory.appendingPathComponent("bin").path)
    }

    /// `providers` is the set of detected provider ids (e.g. from
    /// `DetectionSummary.foundCustomerIds`). When nil, every writer installs
    /// regardless of detection, which is the fallback behavior when no
    /// caller has a detection result yet. When non-nil, a per-provider
    /// writer only installs for a provider that was actually detected, so a
    /// Mac without Grok never gets a Grok writer LaunchAgent.
    static func setUp(paths: Paths, providers: [String]? = nil, fileManager: FileManager = .default) -> Report {
        var report = Report()
        if let issue = installLocationIssue(appExecutable: paths.appExecutable, home: paths.home) {
            report.lines.append(issue)
            report.blocker = issue
            return report
        }
        guard let bundledBin = paths.bundledBinDirectory else {
            report.lines.append("Set up failed: no bundled helpers in this copy.")
            report.blocker = damagedCopyMessage
            return report
        }
        guard let templates = paths.templateDirectory else {
            report.lines.append("Set up failed: no launchd templates in this copy.")
            report.blocker = damagedCopyMessage
            return report
        }

        let binDir = paths.supportDirectory.appendingPathComponent("bin")
        do {
            try copyHelpers(paths: paths, bundledBin: bundledBin, fileManager: fileManager)
            report.lines.append("Copied helpers to \(binDir.path)")
        } catch {
            report.lines.append("Set up failed while copying helpers: \(error.localizedDescription)")
            report.blocker = "Set up couldn’t copy its files: \(error.localizedDescription)"
            return report
        }

        let context = renderContext(paths: paths)
        let detectedProviders = providers.map { Set($0.map { $0.lowercased() }) }
        // A repeat Set up keeps "Open at login" the way the person left it.
        let openAtLoginTurnedOff = loadStamp(paths: paths) != nil
            && !isOpenAtLoginEnabled(paths: paths, fileManager: fileManager)
        for agent in agents {
            if agent.label == appAgentLabel, openAtLoginTurnedOff {
                report.lines.append("\(agent.label): skipped (Open at login is off)")
                continue
            }
            if let provider = agent.provider, let detectedProviders, !detectedProviders.contains(provider.lowercased()) {
                report.lines.append("\(agent.label): skipped (not detected)")
                continue
            }
            let skip = skipReason(agent: agent, nodeAvailable: paths.nodeAvailable, pythonAvailable: paths.pythonAvailable)
            if let skip {
                report.lines.append("\(agent.label): skipped (\(skip))")
                continue
            }
            if agent.label == appAgentLabel, let item = paths.systemLoginItem {
                if enableSystemLoginItem(item, paths: paths, fileManager: fileManager, report: &report) { continue }
            }
            installAgent(agent, templates: templates, context: context, paths: paths, fileManager: fileManager, report: &report)
        }
        if let stamp = currentStamp(paths: paths, fileManager: fileManager) {
            writeStamp(stamp, paths: paths)
        }
        return report
    }

    // MARK: - The app's own login item

    static func defaultSystemLoginItem(env: [String: String] = ProcessInfo.processInfo.environment) -> SystemLoginItem? {
        let overrideSet = env["CODEX_USAGE_HUD_LAUNCHD_DIR"] != nil || env["CODEX_USAGE_HUD_SUPPORT_DIR"] != nil
        return overrideSet ? nil : .mainApp
    }

    static func legacyAppPlist(paths: Paths) -> URL {
        paths.launchdDirectory.appendingPathComponent("\(appAgentLabel).plist")
    }

    /// Registers the macOS login item, then deletes an old bash-wrapper
    /// plist (file only: when launchd started this app, booting the job out
    /// would quit it; without the file it simply doesn't load next login).
    /// Returns false when registration failed, so the caller falls back to
    /// the plist.
    @discardableResult
    static func enableSystemLoginItem(_ item: SystemLoginItem, paths: Paths, fileManager: FileManager, report: inout Report) -> Bool {
        do {
            try item.register()
        } catch {
            report.lines.append("\(appAgentLabel): login item not registered (\(error.localizedDescription)); using the plist")
            return false
        }
        let legacy = legacyAppPlist(paths: paths)
        if fileManager.fileExists(atPath: legacy.path) {
            try? fileManager.removeItem(at: legacy)
            report.lines.append("\(appAgentLabel): replaced the old login plist")
        }
        report.lines.append("\(appAgentLabel): login item on (Usage HUD in Login Items)")
        return true
    }

    /// App launch: a Set up from before 1.3.0 left the bash-wrapper plist.
    /// Moves it to the macOS login item. Only touches a plist this app's
    /// Set up wrote (a `make install` one points at ~/.local/bin).
    @discardableResult
    static func migrateLegacyAppLoginItem(paths: Paths, fileManager: FileManager = .default) -> Report? {
        guard let item = paths.systemLoginItem else { return nil }
        guard installLocationIssue(appExecutable: paths.appExecutable, home: paths.home) == nil else { return nil }
        guard appManagedAgents(paths: paths, fileManager: fileManager).contains(where: { $0.label == appAgentLabel }) else { return nil }
        var report = Report()
        enableSystemLoginItem(item, paths: paths, fileManager: fileManager, report: &report)
        return report
    }

    /// Writes one job's plist and (outside tests) reloads it. The app's own
    /// job is never bootstrapped: Set up runs inside the already-running
    /// app, and a RunAtLoad bootstrap would put up a second menu-bar icon.
    /// The plist is in place for the next login.
    private static func installAgent(
        _ agent: AgentSpec,
        templates: URL,
        context: LaunchdTemplateRenderer.Context,
        paths: Paths,
        fileManager: FileManager,
        report: inout Report
    ) {
        let templateURL = templates.appendingPathComponent("\(agent.label).plist")
        guard let raw = try? String(contentsOf: templateURL, encoding: .utf8) else {
            report.lines.append("\(agent.label): skipped (template missing)")
            return
        }
        let rendered = LaunchdTemplateRenderer.render(raw, context: context)
        let dest = paths.launchdDirectory.appendingPathComponent("\(agent.label).plist")
        do {
            try fileManager.createDirectory(at: paths.launchdDirectory, withIntermediateDirectories: true)
            try rendered.write(to: dest, atomically: true, encoding: .utf8)
        } catch {
            report.lines.append("\(agent.label): failed to write plist (\(error.localizedDescription))")
            return
        }
        if agent.label == appAgentLabel {
            report.lines.append("\(agent.label): plist written (already running; loads at next login)")
        } else if paths.invokeLaunchctl {
            _ = runLaunchctl(["bootout", "gui/\(getuid())/\(agent.label)"])
            let boot = runLaunchctl(["bootstrap", "gui/\(getuid())", dest.path])
            if boot.status == 0 {
                report.lines.append("\(agent.label): loaded")
            } else {
                report.lines.append("\(agent.label): plist written; bootstrap failed: \(boot.lastLine)")
            }
        } else {
            report.lines.append("\(agent.label): plist written (launchctl skipped: override dir)")
        }
    }

    private static func renderContext(paths: Paths) -> LaunchdTemplateRenderer.Context {
        LaunchdTemplateRenderer.Context(
            home: paths.home.path,
            stateDir: paths.stateDirectory.path,
            binDir: paths.supportDirectory.appendingPathComponent("bin").path,
            supportDir: paths.supportDirectory.path,
            appExecutable: paths.appExecutable
        )
    }

    private static func copyHelpers(paths: Paths, bundledBin: URL, fileManager: FileManager) throws {
        let binDir = paths.supportDirectory.appendingPathComponent("bin")
        let logsDir = paths.supportDirectory.appendingPathComponent("logs")
        try fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.launchdDirectory, withIntermediateDirectories: true)
        try replaceDirectory(at: binDir, withContentsOf: bundledBin, fileManager: fileManager)
        chmodTree(binDir, permissions: 0o755, fileManager: fileManager)
    }

    // MARK: - Install stamp (helper refresh after an update)

    /// What Set up installed: the app build, a digest of the bundled helpers
    /// and templates, and the app path the jobs point at. Any difference on
    /// a later launch means the installed jobs run old helpers.
    struct InstallStamp: Codable, Equatable {
        var build: String
        var helpersDigest: String
        var appExecutable: String
    }

    static let stampFilename = "install-stamp.json"

    static func stampURL(paths: Paths) -> URL {
        paths.supportDirectory.appendingPathComponent(stampFilename)
    }

    static func currentStamp(paths: Paths, fileManager: FileManager = .default) -> InstallStamp? {
        guard let bin = paths.bundledBinDirectory, let templates = paths.templateDirectory else { return nil }
        return InstallStamp(
            build: paths.buildNumber,
            helpersDigest: helpersDigest(directories: [bin, templates], fileManager: fileManager),
            appExecutable: paths.appExecutable
        )
    }

    static func loadStamp(paths: Paths) -> InstallStamp? {
        guard let data = try? Data(contentsOf: stampURL(paths: paths)) else { return nil }
        return try? JSONDecoder().decode(InstallStamp.self, from: data)
    }

    static func writeStamp(_ stamp: InstallStamp, paths: Paths) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(stamp) else { return }
        try? FileManager.default.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: stampURL(paths: paths), options: .atomic)
    }

    /// SHA-256 over every file's relative path and bytes, in a fixed order.
    static func helpersDigest(directories: [URL?], fileManager: FileManager = .default) -> String {
        var hasher = SHA256()
        for (index, directory) in directories.enumerated() {
            hasher.update(data: Data("#\(index)\n".utf8))
            guard let directory else { continue }
            let root = directory.standardizedFileURL.path
            let files = (fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])?
                .compactMap { $0 as? URL } ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .map { url -> (String, URL) in
                    let path = url.standardizedFileURL.path
                    let relative = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : url.lastPathComponent
                    return (relative, url)
                }
                .sorted { $0.0 < $1.0 }
            for (relative, url) in files {
                hasher.update(data: Data("\(relative)\n".utf8))
                if let contents = try? Data(contentsOf: url) { hasher.update(data: contents) }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Jobs this app's Set up wrote: their plist runs helpers from its own
    /// Application Support copy. Jobs rendered by `make install` point at
    /// ~/.local/bin and are never touched by the in-app refresh.
    static func appManagedAgents(paths: Paths, fileManager: FileManager = .default) -> [AgentSpec] {
        let marker = LaunchdTemplateRenderer.xmlEscaped(paths.supportDirectory.appendingPathComponent("bin").path)
        return agents.filter { agent in
            let plist = paths.launchdDirectory.appendingPathComponent("\(agent.label).plist")
            guard fileManager.fileExists(atPath: plist.path),
                  let text = try? String(contentsOf: plist, encoding: .utf8)
            else { return false }
            return text.contains(marker + "/") || text.contains(marker + ":") || text.contains(marker + "<")
        }
    }

    /// Tests set both CODEX_USAGE_HUD_LAUNCHD_DIR and CODEX_USAGE_HUD_SUPPORT_DIR;
    /// then only those directories are written and launchctl never runs. One
    /// of them alone, or a throwaway state dir beside the real LaunchAgents,
    /// would mix real jobs with test paths, so the refresh does nothing.
    static func helperRefreshAllowed(env: [String: String], home: URL) -> Bool {
        let overrideKeys = ["CODEX_USAGE_HUD_LAUNCHD_DIR", "CODEX_USAGE_HUD_SUPPORT_DIR"]
        if overrideKeys.contains(where: { env[$0] != nil }) {
            return overrideKeys.allSatisfy { !(env[$0] ?? "").isEmpty }
        }
        if let state = env["CODEX_USAGE_HUD_STATE_DIR"], !state.isEmpty,
           UsagePaths.isIsolatedOverride(state, home: home) {
            return false
        }
        return true
    }

    /// App-launch entry point. When this app's Set up installed jobs and the
    /// bundled helpers, templates, build or app path changed since, re-copies
    /// the helpers and re-renders and reloads exactly the jobs that are
    /// installed. Returns nil when nothing needed doing. Blocking; call it
    /// off the main thread (`refreshInstalledHelpersIfStaleInBackground`).
    @discardableResult
    static func refreshInstalledHelpersIfStale(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Report? {
        guard helperRefreshAllowed(env: env, home: UsagePaths.home) else { return nil }
        return refreshInstalledHelpersIfStale(paths: .resolved(env: env))
    }

    @discardableResult
    static func refreshInstalledHelpersIfStale(paths: Paths, fileManager: FileManager = .default) -> Report? {
        // Never point jobs at a copy running from Downloads or a disk image.
        if installLocationIssue(appExecutable: paths.appExecutable, home: paths.home) != nil { return nil }
        guard let bundledBin = paths.bundledBinDirectory, let templates = paths.templateDirectory else { return nil }
        // "Open at login" alone is not a Set up; copying helpers for it would
        // hide the Set up card without installing any refresh job.
        guard isInstalled(paths: paths, fileManager: fileManager) else { return nil }
        let managed = appManagedAgents(paths: paths, fileManager: fileManager)
        guard !managed.isEmpty, let current = currentStamp(paths: paths, fileManager: fileManager) else { return nil }
        if loadStamp(paths: paths) == current { return nil }

        var report = Report()
        report.lines.append("Updating background jobs for build \(current.build)")
        do {
            try copyHelpers(paths: paths, bundledBin: bundledBin, fileManager: fileManager)
        } catch {
            report.lines.append("Helper refresh failed while copying: \(error.localizedDescription)")
            return report
        }
        let context = renderContext(paths: paths)
        for agent in managed {
            installAgent(agent, templates: templates, context: context, paths: paths, fileManager: fileManager, report: &report)
        }
        writeStamp(current, paths: paths)
        return report
    }

    /// The one call for app launch: runs the check on a utility queue.
    static func refreshInstalledHelpersIfStaleInBackground() {
        DispatchQueue.global(qos: .utility).async {
            let env = ProcessInfo.processInfo.environment
            if helperRefreshAllowed(env: env, home: UsagePaths.home),
               let report = migrateLegacyAppLoginItem(paths: .resolved(env: env)) {
                FileHandle.standardError.write(Data("login item:\n\(report.text)\n".utf8))
            }
            if let report = refreshInstalledHelpersIfStale() {
                FileHandle.standardError.write(Data("helper refresh:\n\(report.text)\n".utf8))
            }
        }
    }

    // MARK: - Open at login

    static func isOpenAtLoginEnabled(paths: Paths? = nil, fileManager: FileManager = .default) -> Bool {
        let launchdDirectory = paths?.launchdDirectory ?? UsagePaths.launchdDirectory
        if fileManager.fileExists(atPath: launchdDirectory.appendingPathComponent("\(appAgentLabel).plist").path) { return true }
        let item = paths.map(\.systemLoginItem) ?? defaultSystemLoginItem()
        return item?.isEnabled() ?? false
    }

    /// On: writes the app's own login item (it loads at next login; the app
    /// is already running). Off: deletes it. Never boots the job out: when
    /// launchd started this app, that would quit it.
    static func setOpenAtLogin(_ enabled: Bool, paths: Paths, fileManager: FileManager = .default) -> Report {
        var report = Report()
        let dest = paths.launchdDirectory.appendingPathComponent("\(appAgentLabel).plist")
        if let item = paths.systemLoginItem {
            if enabled {
                if let issue = installLocationIssue(appExecutable: paths.appExecutable, home: paths.home) {
                    report.blocker = issue
                    report.lines.append(issue)
                    return report
                }
                if enableSystemLoginItem(item, paths: paths, fileManager: fileManager, report: &report) { return report }
                // Registration failed: fall through to the plist.
            } else {
                try? item.unregister()
                report.lines.append("\(appAgentLabel): login item off")
                if fileManager.fileExists(atPath: dest.path) { try? fileManager.removeItem(at: dest) }
                return report
            }
        }
        if enabled {
            if let issue = installLocationIssue(appExecutable: paths.appExecutable, home: paths.home) {
                report.blocker = issue
                report.lines.append(issue)
                return report
            }
            guard let templates = paths.templateDirectory,
                  let raw = try? String(contentsOf: templates.appendingPathComponent("\(appAgentLabel).plist"), encoding: .utf8)
            else {
                report.blocker = damagedCopyMessage
                report.lines.append("\(appAgentLabel): template missing")
                return report
            }
            do {
                try fileManager.createDirectory(at: paths.launchdDirectory, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: paths.supportDirectory.appendingPathComponent("logs"), withIntermediateDirectories: true)
                try LaunchdTemplateRenderer.render(raw, context: renderContext(paths: paths))
                    .write(to: dest, atomically: true, encoding: .utf8)
                report.lines.append("\(appAgentLabel): plist written (loads at next login)")
            } catch {
                report.blocker = "Couldn’t turn on Open at login: \(error.localizedDescription)"
                report.lines.append("\(appAgentLabel): failed to write plist (\(error.localizedDescription))")
            }
        } else if fileManager.fileExists(atPath: dest.path) {
            do {
                try fileManager.removeItem(at: dest)
                report.lines.append("\(appAgentLabel): deleted plist")
            } catch {
                report.blocker = "Couldn’t turn off Open at login: \(error.localizedDescription)"
                report.lines.append("\(appAgentLabel): could not delete plist (\(error.localizedDescription))")
            }
        }
        return report
    }

    /// Installs agents, runs one refresh, kickstarts the Claude writer, then
    /// waits for state files so the first-run card can show per-lane results.
    static func setUpAndRefresh(
        paths: Paths,
        providers: [String],
        fileManager: FileManager = .default,
        waitTimeout: TimeInterval = 20,
        pollInterval: TimeInterval = 0.5,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        now: () -> Date = Date.init,
        onLaneUpdate: (([LaneSetupResult]) -> Void)? = nil
    ) -> SetupOutcome {
        var lanes = providers.map {
            LaneSetupResult(provider: $0, name: UsageInsights.label(for: $0), status: .running)
        }
        onLaneUpdate?(lanes)

        var report = setUp(paths: paths, providers: providers, fileManager: fileManager)
        if let blocker = report.blocker {
            // Nothing was installed, so there are no lane results to score;
            // scoring here used to report "Claude ✗ not signed in".
            onLaneUpdate?([])
            return SetupOutcome(report: report, lanes: [], hasData: false, blocker: blocker)
        }
        report.lines.append(contentsOf: refreshNow(paths: paths, trigger: .setup).lines)
        if providers.contains(where: { $0.lowercased() == "claude" }) {
            let writerPlist = paths.launchdDirectory.appendingPathComponent("\(ClaudeNativeCoexistence.writerLabel).plist")
            if fileManager.fileExists(atPath: writerPlist.path) {
                report.lines.append(contentsOf: kickstartClaudeWriter(paths: paths).lines)
            } else {
                report.lines.append("\(ClaudeNativeCoexistence.writerLabel): kickstart skipped (not installed)")
            }
        }
        // Without Node.js no writer job can produce a file, so only the
        // in-app Claude reader's file is worth waiting for.
        let waitProviders = providers.filter { id in
            let provider = id.lowercased()
            guard ["claude", "codex", "gemini", "grok"].contains(provider) else { return false }
            return paths.nodeAvailable || provider == "claude"
        }
        waitForUsageFiles(
            providers: waitProviders,
            stateDirectory: paths.stateDirectory,
            timeout: waitTimeout,
            pollInterval: pollInterval,
            sleep: sleep,
            now: now,
            fileExists: { fileManager.fileExists(atPath: $0.path) }
        )
        lanes = LaneSetupScoring.score(
            providers: providers,
            stateDirectory: paths.stateDirectory,
            nodeAvailable: paths.nodeAvailable,
            pythonAvailable: paths.pythonAvailable,
            codexSessionsRoot: paths.codexSessionsRoot
        )
        onLaneUpdate?(lanes)
        for lane in lanes {
            report.lines.append(lane.line)
        }
        return SetupOutcome(report: report, lanes: lanes, hasData: LaneSetupScoring.hasUsableData(lanes))
    }

    static func kickstartClaudeWriter(paths: Paths) -> Report {
        var report = Report()
        if !paths.invokeLaunchctl {
            report.lines.append("com.codexusagehud.claude-writer: kickstart skipped (override dir)")
            return report
        }
        let result = runLaunchctl(["kickstart", "-k", "gui/\(getuid())/com.codexusagehud.claude-writer"])
        if result.status == 0 {
            report.lines.append("com.codexusagehud.claude-writer: kickstarted")
        } else {
            report.lines.append("com.codexusagehud.claude-writer: kickstart failed: \(result.lastLine)")
        }
        return report
    }

    static func waitForUsageFiles(
        providers: [String],
        stateDirectory: URL,
        timeout: TimeInterval,
        pollInterval: TimeInterval,
        sleep: (TimeInterval) -> Void,
        now: () -> Date,
        fileExists: (URL) -> Bool
    ) {
        guard timeout > 0, !providers.isEmpty else { return }
        let deadline = now().addingTimeInterval(timeout)
        while now() < deadline {
            let pending = providers.filter { provider in
                !UsagePaths.usageFilenames(for: provider).contains {
                    fileExists(stateDirectory.appendingPathComponent($0))
                }
            }
            if pending.isEmpty { return }
            sleep(min(pollInterval, max(0, deadline.timeIntervalSince(now()))))
        }
    }

    static func refreshNow(paths: Paths, trigger: ClaudeNativeTrigger = .manual) -> Report {
        var report = Report()
        if let claudeNative = paths.claudeNative {
            report.lines.append("Claude in-app reader: \(claudeNative(trigger).line)")
        }
        let refresh = paths.supportDirectory.appendingPathComponent("bin/codex-usage-refresh")
        guard FileManager.default.isExecutableFile(atPath: refresh.path) else {
            report.lines.append("Refresh now: run Set up first.")
            return report
        }
        // Every writer that script runs is a Node.js program; without Node it
        // can only fail. Claude and Codex are already read in-app.
        if !paths.nodeAvailable {
            report.lines.append("Refresh now: Gemini and Grok need Node.js. Claude and Codex are read in the app.")
            return report
        }
        var env = ProcessInfo.processInfo.environment
        env["CODEX_USAGE_HUD_STATE_DIR"] = paths.stateDirectory.path
        env["BLOOM_USAGE_BIN_DIR"] = paths.supportDirectory.appendingPathComponent("bin").path
        env["PATH"] = [
            paths.supportDirectory.appendingPathComponent("bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            env["PATH"] ?? "",
        ].joined(separator: ":")
        let result = runProcess(
            executable: "/bin/bash",
            arguments: [refresh.path],
            environment: env
        )
        report.lines.append("exit \(result.status)")
        report.lines.append(result.lastLine.isEmpty ? "(no output)" : result.lastLine)
        return report
    }

    static func remove(paths: Paths, fileManager: FileManager = .default) -> Report {
        var report = Report()
        for agent in agents {
            if agent.label == appAgentLabel {
                // Booting the app's own job out would quit this app when
                // launchd started it; deleting its plist is enough.
                if let item = paths.systemLoginItem {
                    try? item.unregister()
                    report.lines.append("\(agent.label): login item off")
                }
                report.lines.append("\(agent.label): left running (no login item after this)")
            } else if paths.invokeLaunchctl {
                let boot = runLaunchctl(["bootout", "gui/\(getuid())/\(agent.label)"])
                if boot.status == 0 {
                    report.lines.append("\(agent.label): unloaded")
                } else {
                    report.lines.append("\(agent.label): bootout skipped or already unloaded")
                }
            } else {
                report.lines.append("\(agent.label): launchctl skipped (override dir)")
            }
            let dest = paths.launchdDirectory.appendingPathComponent("\(agent.label).plist")
            if fileManager.fileExists(atPath: dest.path) {
                do {
                    try fileManager.removeItem(at: dest)
                    report.lines.append("\(agent.label): deleted plist")
                } catch {
                    report.lines.append("\(agent.label): could not delete plist (\(error.localizedDescription))")
                }
            } else {
                report.lines.append("\(agent.label): no plist")
            }
        }
        // The copied helpers only serve those jobs; without them a later
        // "Open at login" must not read as a finished Set up.
        for leftover in [stampURL(paths: paths),
                         paths.supportDirectory.appendingPathComponent("bin")]
        where fileManager.fileExists(atPath: leftover.path) {
            do {
                try fileManager.removeItem(at: leftover)
                report.lines.append("deleted \(leftover.lastPathComponent)")
            } catch {
                report.lines.append("could not delete \(leftover.lastPathComponent) (\(error.localizedDescription))")
            }
        }
        return report
    }

    static func runDiagnostics(paths: Paths) -> Report {
        var report = Report()
        guard paths.nodeAvailable else {
            report.lines.append("The health check needs Node.js 18 or later. Claude and Codex still work without it. Install Node.js from nodejs.org or Homebrew to run the check.")
            return report
        }
        let supportDoctor = paths.supportDirectory.appendingPathComponent("bin/codex-usage-doctor")
        let bundledDoctor = paths.bundledBinDirectory?.appendingPathComponent("codex-usage-doctor")
        let doctor: URL
        // An app update must not run an older helper copied during a previous setup.
        if let bundledDoctor, FileManager.default.isExecutableFile(atPath: bundledDoctor.path) {
            doctor = bundledDoctor
        } else if FileManager.default.isExecutableFile(atPath: supportDoctor.path) {
            doctor = supportDoctor
        } else {
            report.lines.append("Set up first so the health check is available.")
            return report
        }
        // codex-usage-doctor is a Node script; run it through the bloom-node
        // shim so it resolves node the same way the writers do, instead of
        // handing JavaScript to /bin/bash.
        let supportNode = paths.supportDirectory.appendingPathComponent("bin/bloom-node")
        let bundledNode = paths.bundledBinDirectory?.appendingPathComponent("bloom-node")
        let node: URL
        if FileManager.default.isExecutableFile(atPath: supportNode.path) {
            node = supportNode
        } else if let bundledNode, FileManager.default.isExecutableFile(atPath: bundledNode.path) {
            node = bundledNode
        } else {
            report.lines.append("Set up first so the health check is available.")
            return report
        }
        var env = ProcessInfo.processInfo.environment
        env["CODEX_USAGE_HUD_STATE_DIR"] = paths.stateDirectory.path
        env["BLOOM_USAGE_BIN_DIR"] = paths.supportDirectory.appendingPathComponent("bin").path
        env["PATH"] = [
            paths.supportDirectory.appendingPathComponent("bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            env["PATH"] ?? "",
        ].joined(separator: ":")
        let result = runProcess(
            executable: node.path,
            arguments: [doctor.path],
            environment: env
        )
        if !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            report.lines.append(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            report.lines.append("exit \(result.status)")
        }
        return report
    }

    /// A translocated copy (Gatekeeper's "AppTranslocation" mirror of a
    /// just-downloaded, un-trusted app) or a copy run straight out of
    /// Downloads/Desktop/a zip would write that temp or non-standard path
    /// into the login plist. Set up must refuse and ask for a move instead.
    static func installLocationIssue(appExecutable: String, home: URL) -> String? {
        let next = "Move Usage HUD to Applications, then open it again."
        if appExecutable.contains("/AppTranslocation/") {
            return "macOS opened Usage HUD from a temporary copy. \(next)"
        }
        guard let bundlePath = appBundlePath(fromExecutable: appExecutable) else {
            return "Usage HUD isn’t running as an app. \(next)"
        }
        let systemApplications = "/Applications/"
        let userApplications = home.appendingPathComponent("Applications", isDirectory: true).path + "/"
        if bundlePath.hasPrefix(systemApplications) || bundlePath.hasPrefix(userApplications) {
            return nil
        }
        let place: String
        if bundlePath.hasPrefix(home.appendingPathComponent("Downloads").path + "/") {
            place = "Usage HUD is open from your Downloads folder."
        } else if bundlePath.hasPrefix(home.appendingPathComponent("Desktop").path + "/") {
            place = "Usage HUD is open from your Desktop."
        } else if bundlePath.hasPrefix("/Volumes/") {
            place = "Usage HUD is open from a disk image."
        } else {
            place = "Usage HUD isn’t in your Applications folder."
        }
        return "\(place) \(next)"
    }

    private static func appBundlePath(fromExecutable executable: String) -> String? {
        var url = URL(fileURLWithPath: executable)
        while !url.pathComponents.isEmpty, url.pathComponents != ["/"] {
            if url.pathExtension == "app" { return url.path + "/" }
            url.deleteLastPathComponent()
        }
        return nil
    }

    static func skipReason(agent: AgentSpec, nodeAvailable: Bool, pythonAvailable: Bool) -> String? {
        if agent.needsNode && !nodeAvailable { return "needs Node.js" }
        if agent.needsPython && !pythonAvailable { return "needs Python 3" }
        return nil
    }

    private static func replaceDirectory(at dest: URL, withContentsOf source: URL, fileManager: FileManager) throws {
        if fileManager.fileExists(atPath: dest.path) {
            try fileManager.removeItem(at: dest)
        }
        try fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: dest)
    }

    private static func chmodTree(_ root: URL, permissions: Int, fileManager: FileManager) {
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        while let item = enumerator.nextObject() as? URL {
            try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: item.path)
        }
        try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: root.path)
    }

    private struct ProcessResult {
        var status: Int32
        var output: String
        var lastLine: String {
            let lines = output.split(whereSeparator: \.isNewline).map(String.init)
            return lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    private static func runLaunchctl(_ arguments: [String]) -> ProcessResult {
        runProcess(executable: "/bin/launchctl", arguments: arguments, environment: nil)
    }

    private static func runProcess(executable: String, arguments: [String], environment: [String: String]?) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ProcessResult(status: 127, output: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return ProcessResult(status: process.terminationStatus, output: output)
    }
}
