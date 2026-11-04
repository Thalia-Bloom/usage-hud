import Foundation

/// `usage-hud setup` and `usage-hud detect`: the panel's Set up button for
/// agents. Detection is `ToolDetection.detect()`, installation is
/// `BackgroundRefreshService.setUpAndRefresh` (the same call the button
/// makes), and the first reading is scored by `LaneSetupScoring`. This file
/// only shapes those results into one line per lane, as text or JSON.
enum AgentSetup {
    static let schemaVersion = 1

    struct Lane: Codable, Equatable {
        /// Provider id: claude, codex, gemini, grok, local.
        var id: String
        /// Lane name as the panel shows it.
        var displayName: String
        /// The tool detection looks for (Claude Code, Codex, Gemini, Grok, Ollama).
        var tool: String
        var found: Bool
        /// Detection's own words, e.g. "Claude Code credentials file".
        var detail: String
        /// True when this lane's background job is in place after the command.
        var installed: Bool
        /// One line about the background job: loaded, skipped and why, or not needed.
        var job: String?
        /// The first reading, e.g. "9% of the week used", or null.
        var reading: String?
        /// What to do before running setup again, or null when nothing is needed.
        var nextAction: String?

        /// Every documented key is always present; absent values encode as null.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(displayName, forKey: .displayName)
            try c.encode(tool, forKey: .tool)
            try c.encode(found, forKey: .found)
            try c.encode(detail, forKey: .detail)
            try c.encode(installed, forKey: .installed)
            try c.encode(job, forKey: .job)
            try c.encode(reading, forKey: .reading)
            try c.encode(nextAction, forKey: .nextAction)
        }
    }

    struct Report: Codable, Equatable {
        var schemaVersion = AgentSetup.schemaVersion
        /// "setup" or "detect".
        var command: String
        /// True when at least one lane has a reading or an installed job.
        var ok: Bool
        /// True when no supported tool was found (exit code 3).
        var nothingFound: Bool
        /// Set when Set up could not run at all (wrong location, damaged copy).
        var blocker: String?
        var message: String
        var lanes: [Lane]
        var notes: [String]

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(schemaVersion, forKey: .schemaVersion)
            try c.encode(command, forKey: .command)
            try c.encode(ok, forKey: .ok)
            try c.encode(nothingFound, forKey: .nothingFound)
            try c.encode(blocker, forKey: .blocker)
            try c.encode(message, forKey: .message)
            try c.encode(lanes, forKey: .lanes)
            try c.encode(notes, forKey: .notes)
        }
    }

    // MARK: - detect

    /// Detection only. Reads which jobs and readings already exist; changes nothing.
    static func detectReport(
        summary: DetectionSummary,
        launchdDirectory: URL = UsagePaths.launchdDirectory,
        stateDirectory: URL = UsagePaths.stateDirectory,
        fileManager: FileManager = .default
    ) -> Report {
        let lanes = DetectionSummary.customerOrder.map { entry -> Lane in
            let presence = summary.presence(for: entry.id)
            var lane = Lane(
                id: entry.id,
                displayName: UsageInsights.label(for: entry.id),
                tool: entry.displayName,
                found: presence.isFound,
                detail: presence.reason,
                installed: jobInstalled(for: entry.id, launchdDirectory: launchdDirectory, fileManager: fileManager),
                job: nil,
                reading: nil,
                nextAction: nil
            )
            if let snapshot = LaneSetupScoring.loadSnapshot(provider: entry.id, stateDirectory: stateDirectory) {
                let scored = LaneSetupScoring.result(provider: entry.id, snapshot: snapshot,
                                                     nodeAvailable: summary.node.isFound, pythonAvailable: summary.python3.isFound)
                if case .success(let detail) = scored.status { lane.reading = readingText(detail, name: lane.displayName) }
            }
            if !presence.isFound { lane.nextAction = notFoundAction(for: entry.id, reason: presence.reason) }
            return lane
        }
        let found = lanes.filter(\.found)
        var notes: [String] = []
        if let runtime = summary.runtimeNote { notes.append(runtime) }
        return Report(
            command: "detect",
            ok: !found.isEmpty,
            nothingFound: found.isEmpty,
            blocker: nil,
            message: found.isEmpty
                ? "No supported tool was found on this Mac."
                : [summary.foundLine, summary.missingLine].compactMap { $0 }.joined(separator: ". ") + ".",
            lanes: lanes,
            notes: notes
        )
    }

    // MARK: - setup

    /// What the Set up button does, for the command line. `recordDetection`
    /// saves the detection result the way Settings' Detect again does, so the
    /// lanes found are turned on before the app next opens.
    static func runSetup(
        summary: DetectionSummary,
        paths: BackgroundRefreshService.Paths = .resolved(),
        fileManager: FileManager = .default,
        waitTimeout: TimeInterval = 20,
        recordDetection: (DetectionSummary) -> Void = { ProviderPreferences.applyDetection($0) }
    ) -> Report {
        let providers = summary.foundCustomerIds
        var notes: [String] = []
        if let runtime = summary.runtimeNote { notes.append(runtime) }

        if providers.isEmpty {
            var report = detectReport(summary: summary, launchdDirectory: paths.launchdDirectory,
                                      stateDirectory: paths.stateDirectory, fileManager: fileManager)
            report.command = "setup"
            report.message = "No supported tool was found on this Mac. Nothing was installed."
            report.notes = notes
            return report
        }

        recordDetection(summary)
        let outcome = BackgroundRefreshService.setUpAndRefresh(
            paths: paths,
            providers: providers,
            fileManager: fileManager,
            waitTimeout: waitTimeout
        )
        let lines = outcome.report.lines

        let lanes = DetectionSummary.customerOrder.map { entry -> Lane in
            let presence = summary.presence(for: entry.id)
            let name = UsageInsights.label(for: entry.id)
            var lane = Lane(
                id: entry.id,
                displayName: name,
                tool: entry.displayName,
                found: presence.isFound,
                detail: presence.reason,
                installed: false,
                job: nil,
                reading: nil,
                nextAction: nil
            )
            guard presence.isFound else {
                lane.nextAction = notFoundAction(for: entry.id, reason: presence.reason)
                return lane
            }
            if let blocker = outcome.blocker {
                lane.nextAction = blocker
                return lane
            }
            lane.installed = jobInstalled(for: entry.id, launchdDirectory: paths.launchdDirectory, fileManager: fileManager)
            lane.job = jobLine(for: entry.id, name: name, reportLines: lines, installed: lane.installed)
            if let scored = outcome.lanes.first(where: { $0.provider == entry.id }) {
                switch scored.status {
                case .success(let detail):
                    lane.reading = readingText(detail, name: name)
                case .failure(let detail):
                    lane.nextAction = failureAction(for: entry.id, tool: entry.displayName, detail: detail)
                case .pending, .running:
                    break
                }
            }
            return lane
        }

        if let blocker = outcome.blocker {
            return Report(command: "setup", ok: false, nothingFound: false, blocker: blocker,
                          message: "Set up did not run. \(blocker)", lanes: lanes, notes: notes)
        }

        notes.append(contentsOf: loginItemNotes(reportLines: lines))
        let ok = lanes.contains { $0.reading != nil || $0.installed }
        let withReading = lanes.filter { $0.reading != nil }.map(\.displayName)
        let message: String
        if !withReading.isEmpty {
            message = "Set up complete. First reading: \(withReading.joined(separator: ", "))."
        } else if ok {
            message = "Set up complete. Background refresh is installed; no reading yet. Follow each lane's next action."
        } else {
            message = "Set up ran but installed nothing usable. Follow each lane's next action, then run setup again."
        }
        return Report(command: "setup", ok: ok, nothingFound: false, blocker: nil, message: message, lanes: lanes, notes: notes)
    }

    // MARK: - Text

    static func text(_ report: Report) -> String {
        var out = [report.message]
        let width = report.lanes.map(\.displayName.count).max() ?? 0
        for lane in report.lanes {
            var parts: [String] = []
            parts.append(lane.found ? "found (\(lane.detail))" : "not found (\(lane.detail))")
            if let job = lane.job { parts.append("job: \(job)") }
            if let reading = lane.reading { parts.append("reading: \(reading)") }
            if let next = lane.nextAction { parts.append("next: \(next)") }
            let name = lane.displayName.padding(toLength: width, withPad: " ", startingAt: 0)
            out.append("\(name)  \(parts.joined(separator: " · "))")
        }
        if !report.notes.isEmpty {
            out.append("")
            out.append(contentsOf: report.notes.map { "Note: \($0)" })
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Pieces

    static func agentLabel(for provider: String) -> String? {
        BackgroundRefreshService.agents.first { $0.provider == provider }?.label
    }

    static func jobInstalled(for provider: String, launchdDirectory: URL, fileManager: FileManager) -> Bool {
        guard let label = agentLabel(for: provider) else { return false }
        return fileManager.fileExists(atPath: launchdDirectory.appendingPathComponent("\(label).plist").path)
    }

    /// The Set up report's line for this lane's job, in plain words.
    static func jobLine(for provider: String, name: String, reportLines: [String], installed: Bool) -> String {
        guard let label = agentLabel(for: provider) else {
            return "not needed (\(name) is read in the app)"
        }
        // The install line comes first; a later kickstart line is not the job's state.
        let prefix = "\(label): "
        let line = reportLines.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        if let line, line.hasPrefix("skipped (needs"), ["claude", "codex"].contains(provider) {
            return "\(line); \(name) is read in the app instead"
        }
        if let line { return line }
        return installed ? "installed" : "not installed"
    }

    /// "Claude ✓ 9% of the week used" -> "9% of the week used".
    static func readingText(_ detail: String, name: String) -> String {
        let marker = "\(name) ✓ "
        if detail.hasPrefix(marker) { return String(detail.dropFirst(marker.count)) }
        return detail
    }

    static func notFoundAction(for provider: String, reason: String) -> String {
        switch provider {
        case "claude":
            return reason.contains("not signed in")
                ? "Sign in to Claude Code, then run setup again."
                : "Install Claude Code and sign in, then run setup again."
        case "codex":
            return "Install Codex and run one session, then run setup again."
        case "gemini":
            return "Install the Antigravity CLI (agy) and sign in to Gemini, then run setup again."
        case "grok":
            return "Sign in to Grok, then run setup again."
        case "local":
            return "Install and start Ollama, then run setup again."
        default:
            return "Install or sign in, then run setup again."
        }
    }

    /// A `LaneSetupScoring` failure line, turned into the next step.
    static func failureAction(for provider: String, tool: String, detail: String) -> String {
        if detail.contains("usage rate-limited") {
            return "Keep Usage HUD open; it will retry automatically after the usage endpoint's cooldown. No sign-in or setup change is needed."
        }
        if detail.contains("needs Node.js") {
            return "Install Node.js 18 or later (nodejs.org or Homebrew), then run setup again."
        }
        if detail.contains("not signed in") {
            return "Sign in to \(tool), then run setup again."
        }
        if detail.contains("start Ollama") {
            return "Start Ollama, then run setup again."
        }
        if detail.contains("no session yet") {
            return "Run one Codex session, then run setup again."
        }
        if detail.contains("broken") {
            return "Open Usage HUD Settings and click Run diagnostics."
        }
        return "Use \(tool) once so it records usage, then run setup again."
    }

    /// The GUI registers the app's own login item through macOS; from the
    /// command line that can fail, and Set up then writes a login plist the
    /// app replaces on its next launch. Say so instead of failing.
    static func loginItemNotes(reportLines: [String]) -> [String] {
        let app = BackgroundRefreshService.appAgentLabel
        let appLines = reportLines.filter { $0.hasPrefix("\(app): ") }
        if appLines.contains(where: { $0.contains("login item not registered") || $0.contains("plist written") }) {
            return ["Open at login was not registered from the command line; Usage HUD registers it the next time the app opens."]
        }
        return []
    }
}
