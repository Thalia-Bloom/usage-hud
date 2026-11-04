import Foundation

enum UsagePaths {
    static let appSupportName = "Codex Usage HUD"

    static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static var stateDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_USAGE_HUD_STATE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        return home.appendingPathComponent(".codex-usage-hud")
    }

    /// True when `CODEX_USAGE_HUD_STATE_DIR` points somewhere other than the
    /// canonical home state dir. Fixture renders and empty-state snapshots
    /// use this so live ~/.codex-usage-hud files cannot leak into a throwaway
    /// directory. Launchd still sets the canonical path, so the installed app
    /// is not isolated.
    static var isIsolatedStateDir: Bool {
        guard let override = ProcessInfo.processInfo.environment["CODEX_USAGE_HUD_STATE_DIR"], !override.isEmpty else {
            return false
        }
        return isIsolatedOverride(override, home: home)
    }

    static func isIsolatedOverride(_ override: String, home: URL) -> Bool {
        let path = expand(override, home: home)
        return path != expand("~/.codex-usage-hud", home: home)
    }

    private static func expand(_ path: String, home: URL) -> String {
        if path == "~" { return home.standardizedFileURL.path }
        if path.hasPrefix("~/") {
            return home.appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL.path
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    static var appSupportDirectory: URL {
        supportDirectory
    }

    /// Buyer helpers and logs. Override with `CODEX_USAGE_HUD_SUPPORT_DIR`
    /// so tests never write into the real Application Support folder.
    static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_USAGE_HUD_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        return home.appendingPathComponent("Library/Application Support/\(appSupportName)")
    }

    /// LaunchAgent destination. Override with `CODEX_USAGE_HUD_LAUNCHD_DIR`
    /// so tests and isolated slices never write into ~/Library/LaunchAgents.
    static var launchdDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_USAGE_HUD_LAUNCHD_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        return home.appendingPathComponent("Library/LaunchAgents")
    }

    static var installedBinDirectory: URL {
        supportDirectory.appendingPathComponent("bin")
    }

    static var stateDirectoriesForRead: [URL] {
        [stateDirectory]
    }

    static var appSupportStateDirectoriesForRead: [URL] {
        if isIsolatedStateDir { return [] }
        return [appSupportDirectory.appendingPathComponent("state")]
    }

    static var displayStatePath: String {
        abbreviate(stateDirectory)
    }

    /// Written only by the in-app Claude reader (ClaudeNativeUsageReader),
    /// never by a LaunchAgent, so the two producers never share a file.
    static let claudeNativeUsageFilename = "claude-usage-native.json"

    /// Snapshot filenames a provider's lane may be read from; the newest wins.
    static func usageFilenames(for provider: String) -> [String] {
        let primary = "\(provider)-usage.json"
        return provider.lowercased() == "claude" ? [primary, claudeNativeUsageFilename] : [primary]
    }

    static func providerUsageCandidates(_ provider: String) -> [URL] {
        let filenames = usageFilenames(for: provider)
        return unique(
            stateDirectoriesForRead.flatMap { dir in filenames.map { dir.appendingPathComponent($0) } } +
            appSupportStateDirectoriesForRead.flatMap { dir in filenames.map { dir.appendingPathComponent($0) } }
        )
    }

    static func budgetStateCandidates(provider: String) -> [URL] {
        let filename = provider.lowercased() == "claude"
            ? "token-budget-state.json"
            : "token-budget-state-\(provider.lowercased()).json"
        return stateDirectoriesForRead.map { $0.appendingPathComponent(filename) }
    }

    static func budgetStateURL(provider: String) -> URL {
        budgetStateCandidates(provider: provider).first ?? stateDirectory.appendingPathComponent("token-budget-state-\(provider).json")
    }

    static var policyCandidates: [URL] {
        stateDirectoriesForRead.map { $0.appendingPathComponent("token-budget.json") }
    }

    static var overrideCandidates: [URL] {
        stateDirectoriesForRead.map { $0.appendingPathComponent("override-until.txt") }
    }

    static var overrideURL: URL {
        stateDirectory.appendingPathComponent("override-until.txt")
    }

    static func ensureStateDirectory() {
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
    }

    static func abbreviate(_ url: URL) -> String {
        let path = url.path
        let homePath = home.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") {
            return "~" + path.dropFirst(homePath.count)
        }
        return path
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
