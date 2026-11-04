import Foundation

/// Completion of the existing meter-only helper, not a promise of fresh billing data.
enum ManualRefreshOutcome: Equatable, Sendable {
    case completed
    case alreadyRunning
    case unavailable
    case failed(Int32)
    case timedOut
}

struct ManualRefreshFeedback: Equatable, Sendable {
    var title: String
    var detail: String
    var needsAttention: Bool
    var checkedAt: Date?

    static let refreshing = ManualRefreshFeedback(
        title: "Refreshing…",
        detail: "Checking available usage sources. Provider limits and retry delays still apply.",
        needsAttention: false,
        checkedAt: nil
    )

    static func finished(
        _ outcome: ManualRefreshOutcome,
        before: [UsageSnapshot],
        after: [UsageSnapshot],
        providers: Set<String>,
        now: Date = Date()
    ) -> ManualRefreshFeedback {
        switch outcome {
        case .unavailable:
            return .init(title: "Refresh needs setup", detail: "Open Settings and choose Set up. This copy has no usable refresh helper.", needsAttention: true, checkedAt: nil)
        case .failed:
            return .init(title: "Refresh couldn't finish", detail: "We couldn't get new usage readings. Showing the latest available readings. Open Help › Run health check to find out what went wrong.", needsAttention: true, checkedAt: nil)
        case .alreadyRunning:
            return .init(title: "Already refreshing", detail: "A background refresh is already running. New readings appear automatically; no duplicate refresh was started.", needsAttention: false, checkedAt: nil)
        case .timedOut:
            return .init(title: "Refresh is taking longer", detail: "Still running in the background. Existing readings remain visible and new readings appear automatically. No provider process was stopped.", needsAttention: true, checkedAt: nil)
        case .completed:
            break
        }

        let selected = after.filter { providers.contains($0.provider.lowercased()) }
        // A manual/observation lane never refreshes on its own, so
        // its age must not count toward "some readings unavailable" — that
        // warning, and the orange footer it drives, are meant for the
        // always-on lanes this refresh can actually check. A real change on
        // a manual lane can still report as "Updated" below.
        let unavailable = providers
            .filter { !UsageInsights.isManualObservationLane($0, snapshots: after) }
            .filter { id in
                guard let snapshot = selected.first(where: { $0.provider.lowercased() == id }) else { return true }
                let usable = snapshot.week?.usedPct != nil || snapshot.currentSession?.usedPct != nil
                    || (id == "local" && snapshot.session?.todayTotal != nil)
                return !usable || UsageInsights.freshness(for: snapshot, now: now).rank >= 3
            }.sorted()
        let changed = selected.filter { snapshot in
            guard let old = before.first(where: { $0.provider == snapshot.provider }) else { return true }
            // Do not use checkedAt/updatedAt: a collector may rewrite cached data.
            return snapshot.capturedAt != old.capturedAt || snapshot.eventAt != old.eventAt
                || snapshot.week?.usedPct != old.week?.usedPct
                || snapshot.currentSession?.usedPct != old.currentSession?.usedPct
                || snapshot.session?.todayTotal != old.session?.todayTotal
        }.count
        let detail: String
        if !unavailable.isEmpty {
            let names = unavailable.map { UsageInsights.label(for: $0) }.joined(separator: ", ")
            detail = "Check finished. Still unavailable or old: \(names). A refresh does not bypass provider limits or make cached readings new."
        } else if changed == 0 {
            detail = "Check finished. No new readings were available; existing values and observation times were preserved."
        } else {
            detail = "Check finished. \(changed) usage source\(changed == 1 ? "" : "s") changed. Each meter retains its own observation time."
        }
        return .init(
            title: !unavailable.isEmpty ? "Checked · some readings unavailable" : changed == 0 ? "Checked · no new readings" : "Updated",
            detail: detail,
            needsAttention: !unavailable.isEmpty,
            checkedAt: now
        )
    }
}

/// Runs off the main actor. It uses the same meter-only script and lock as the
/// scheduled refresh, with no forced provider fetches, login changes or new timers.
enum ManualRefreshService {
    static let busyExitStatus: Int32 = 75

    static func run(timeout: TimeInterval = 90) -> ManualRefreshOutcome {
        // The in-app Claude reader honors its own floor and 429 window, and
        // stands down whenever the claude-writer LaunchAgent owns the lane.
        let claude = ClaudeNativeUsageService.shared.run(trigger: .manual)
        let fm = FileManager.default
        let candidates = [
            BundledHelpers.bundledBinDirectory()?.appendingPathComponent("codex-usage-refresh"),
            UsagePaths.supportDirectory.appendingPathComponent("bin/codex-usage-refresh"),
            UsagePaths.home.appendingPathComponent(".local/bin/codex-usage-refresh")
        ].compactMap { $0 }
        guard let script = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) else {
            if case .fetched = claude { return .completed }
            return .unavailable
        }
        // Every writer the script runs is a Node.js program; without Node it
        // can only fail. Claude and Codex are read in-app, so the check is done.
        if !RuntimeDependencies.nodeAvailable {
            return .completed
        }
        var env = ProcessInfo.processInfo.environment
        env["CODEX_USAGE_HUD_STATE_DIR"] = UsagePaths.stateDirectory.path
        env["BLOOM_USAGE_BIN_DIR"] = script.deletingLastPathComponent().path
        env["CODEX_USAGE_HUD_MANUAL_REFRESH"] = "1"
        env["PATH"] = [script.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        return run(script: script, environment: env, timeout: timeout)
    }

    /// Injectable path/environment support isolated tests; no live account is needed.
    static func run(script: URL, environment: [String: String], timeout: TimeInterval) -> ManualRefreshOutcome {
        guard timeout > 0, FileManager.default.isExecutableFile(atPath: script.path) else { return .unavailable }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.environment = environment
        // Provider output is neither exposed nor held in a pipe that could fill.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in }
        do { try process.run() }
        catch { return .unavailable }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning {
            if ProcessInfo.processInfo.systemUptime >= deadline {
                // Never kill a shared provider operation to make the UI finish.
                return .timedOut
            }
            Thread.sleep(forTimeInterval: min(0.1, max(0.001, deadline - ProcessInfo.processInfo.systemUptime)))
        }
        switch process.terminationStatus {
        case 0: return .completed
        case busyExitStatus: return .alreadyRunning
        default: return .failed(process.terminationStatus)
        }
    }
}
