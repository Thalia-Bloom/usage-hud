import Foundation

struct ProviderDefinition: Identifiable, Sendable {
    let id: String
    let name: String
    let shortName: String
    let glyph: String
    let sourceDescription: String
}

enum ProviderCatalog {
    static let all: [ProviderDefinition] = [
        ProviderDefinition(id: "codex", name: "Codex", shortName: "CX", glyph: "X", sourceDescription: "Codex session logs"),
        ProviderDefinition(id: "claude", name: "Claude", shortName: "CL", glyph: "C", sourceDescription: "Claude Code sign-in"),
        ProviderDefinition(id: "gemini", name: "Gemini", shortName: "GM", glyph: "G", sourceDescription: "Antigravity CLI quota"),
        ProviderDefinition(id: "grok", name: "Grok", shortName: "GK", glyph: "K", sourceDescription: "Grok subscription usage"),
        ProviderDefinition(id: "local", name: "Local Models", shortName: "LC", glyph: "L", sourceDescription: "Ollama on this Mac"),
    ]

    /// Customer-facing rows: every provider in the catalog.
    static var displayProviders: [ProviderDefinition] { all }

    static var ids: [String] { all.map(\.id) }
    static var displayIds: [String] { displayProviders.map(\.id) }

    static func definition(for id: String) -> ProviderDefinition? {
        all.first { $0.id == id.lowercased() }
    }
}

struct ProviderSelection: Equatable, Sendable {
    let connected: Set<String>
    let shown: Set<String>

    static let all = ProviderSelection(
        connected: Set(ProviderCatalog.ids),
        shown: Set(ProviderCatalog.ids)
    )

    func includes(_ provider: String) -> Bool {
        let id = provider.lowercased()
        return connected.contains(id) && shown.contains(id)
    }
}

struct ProviderPreferencesFile: Codable, Equatable {
    var detectedAt: String?
    var found: [String]
    var missing: [String]
    var connected: [String]
    var shown: [String]
    var setupCompleteAcknowledged: Bool?
    var nodeAvailable: Bool?
    var pythonAvailable: Bool?
    var runtimeNote: String?

    var selection: ProviderSelection {
        ProviderSelection(connected: Set(connected), shown: Set(shown))
    }
}

enum ProviderPreferences {
    static let fileName = "provider-preferences.json"
    static let detectAgainHelp = "Looks for coding tools on this Mac again. Turns lanes on or off to match what it finds."

    static var fileURL: URL {
        UsagePaths.stateDirectory.appendingPathComponent(fileName)
    }

    static func connectedKey(for provider: String) -> String {
        "usageHUD.provider.\(provider.lowercased()).connected"
    }

    static func shownKey(for provider: String) -> String {
        "usageHUD.provider.\(provider.lowercased()).shown"
    }

    static func isConnected(_ provider: String, defaults: UserDefaults = .standard) -> Bool {
        bool(forKey: connectedKey(for: provider), defaultValue: true, defaults: defaults)
    }

    static func isShown(_ provider: String, defaults: UserDefaults = .standard) -> Bool {
        bool(forKey: shownKey(for: provider), defaultValue: true, defaults: defaults)
    }

    /// Only catalog providers count: ids an older build stored for lanes
    /// that no longer exist are dropped silently.
    static func selection(defaults: UserDefaults = .standard, fileURL: URL? = nil) -> ProviderSelection {
        let url = fileURL ?? Self.fileURL
        let known = Set(ProviderCatalog.ids)
        if UsagePaths.isIsolatedStateDir {
            if let stored = loadFile(url) {
                return ProviderSelection(
                    connected: Set(stored.connected).intersection(known),
                    shown: Set(stored.shown).intersection(known)
                )
            }
            return ProviderSelection(connected: known, shown: known)
        }
        return ProviderSelection(
            connected: Set(ProviderCatalog.ids.filter { isConnected($0, defaults: defaults) }),
            shown: Set(ProviderCatalog.ids.filter { isShown($0, defaults: defaults) })
        )
    }

    /// First launch writes detection-derived defaults. An existing preferences
    /// file, or any already-set provider toggle, is left untouched.
    @discardableResult
    static func ensureInitialized(
        defaults: UserDefaults = .standard,
        fileURL: URL? = nil,
        isolated: Bool = UsagePaths.isIsolatedStateDir,
        detect: () -> DetectionSummary = { ToolDetection.detect() }
    ) -> DetectionSummary? {
        let url = fileURL ?? Self.fileURL
        if isolated { return loadFile(url).map(summary(from:)) }
        if loadFile(url) != nil { return loadFile(url).map(summary(from:)) }
        if anyProviderKeySet(defaults: defaults) {
            persistFromDefaults(defaults: defaults, fileURL: url, summary: nil)
            return nil
        }
        let summary = detect()
        applyDetection(summary, defaults: defaults, fileURL: url)
        return summary
    }

    static func applyDetection(
        _ summary: DetectionSummary,
        defaults: UserDefaults = .standard,
        fileURL: URL? = nil,
        now: Date = Date()
    ) {
        let url = fileURL ?? Self.fileURL
        for provider in ProviderCatalog.ids {
            let found = defaultEnabled(provider, summary: summary)
            defaults.set(found, forKey: connectedKey(for: provider))
            defaults.set(found, forKey: shownKey(for: provider))
        }
        writeFile(
            ProviderPreferencesFile(
                detectedAt: isoString(summary.detectedAt),
                found: summary.foundDisplayNames,
                missing: summary.missingDisplayNames,
                connected: ProviderCatalog.ids.filter { defaultEnabled($0, summary: summary) },
                shown: ProviderCatalog.ids.filter { defaultEnabled($0, summary: summary) },
                setupCompleteAcknowledged: loadFile(url)?.setupCompleteAcknowledged,
                nodeAvailable: summary.node.isFound,
                pythonAvailable: summary.python3.isFound,
                runtimeNote: summary.runtimeNote
            ),
            to: url
        )
        notifyChanged()
    }

    /// A lane defaults on exactly when its tool was detected.
    static func defaultEnabled(_ provider: String, summary: DetectionSummary) -> Bool {
        summary.isFound(provider)
    }

    static func detectAgain(
        defaults: UserDefaults = .standard,
        fileURL: URL? = nil,
        detect: () -> DetectionSummary = { ToolDetection.detect() }
    ) -> DetectionSummary {
        let summary = detect()
        applyDetection(summary, defaults: defaults, fileURL: fileURL)
        return summary
    }

    static func storedFile(_ fileURL: URL? = nil) -> ProviderPreferencesFile? {
        loadFile(fileURL ?? Self.fileURL)
    }

    static func detectionSummary(_ fileURL: URL? = nil) -> DetectionSummary? {
        loadFile(fileURL ?? Self.fileURL).map(summary(from:))
    }

    static var setupCompleteAcknowledged: Bool {
        loadFile(fileURL)?.setupCompleteAcknowledged == true
    }

    static func acknowledgeSetupComplete(fileURL: URL? = nil) {
        let url = fileURL ?? Self.fileURL
        guard var stored = loadFile(url) else { return }
        stored.setupCompleteAcknowledged = true
        writeFile(stored, to: url)
    }

    static func notifyChanged() {
        NotificationCenter.default.post(name: .usageHUDProviderPreferencesDidChange, object: nil)
    }

    // MARK: - Found-but-hidden prompt

    /// Generic across every `ProviderCatalog` entry: any lane `ToolDetection`
    /// finds installed/active but the current preferences do not show yet,
    /// and the user has not dismissed the prompt for. A provider only needs
    /// a detection rule in `ToolDetection` to get this "Found X — add it?"
    /// banner; nothing else has to change.
    static func foundButNotShown(
        defaults: UserDefaults = .standard,
        detect: () -> DetectionSummary = { ToolDetection.detect() }
    ) -> [ProviderDefinition] {
        let summary = detect()
        return ProviderCatalog.all.filter { provider in
            return summary.isFound(provider.id)
                && !isShown(provider.id, defaults: defaults)
                && !isFoundPromptDismissed(provider.id, defaults: defaults)
        }
    }

    static func foundPromptDismissedKey(for provider: String) -> String {
        "usageHUD.provider.\(provider.lowercased()).foundPromptDismissed"
    }

    static func isFoundPromptDismissed(_ provider: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: foundPromptDismissedKey(for: provider))
    }

    /// "Not now": hide the banner for this provider without turning it on.
    /// Persisted so it doesn't nag again on the next launch.
    static func dismissFoundPrompt(_ provider: String, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: foundPromptDismissedKey(for: provider))
        notifyChanged()
    }

    /// "Add": turn the detected lane on the same way its Settings toggle would.
    static func addDetectedProvider(_ provider: String, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: connectedKey(for: provider))
        defaults.set(true, forKey: shownKey(for: provider))
        notifyChanged()
    }

    private static func anyProviderKeySet(defaults: UserDefaults) -> Bool {
        ProviderCatalog.ids.contains { provider in
            defaults.object(forKey: connectedKey(for: provider)) != nil
                || defaults.object(forKey: shownKey(for: provider)) != nil
        }
    }

    private static func persistFromDefaults(
        defaults: UserDefaults,
        fileURL: URL,
        summary: DetectionSummary?
    ) {
        writeFile(
            ProviderPreferencesFile(
                detectedAt: summary.map { isoString($0.detectedAt) },
                found: summary?.foundDisplayNames ?? [],
                missing: summary?.missingDisplayNames ?? [],
                connected: ProviderCatalog.ids.filter { isConnected($0, defaults: defaults) },
                shown: ProviderCatalog.ids.filter { isShown($0, defaults: defaults) },
                setupCompleteAcknowledged: false,
                nodeAvailable: summary?.node.isFound,
                pythonAvailable: summary?.python3.isFound,
                runtimeNote: summary?.runtimeNote
            ),
            to: fileURL
        )
    }

    private static func summary(from file: ProviderPreferencesFile) -> DetectionSummary {
        func presence(_ id: String, display: String) -> ToolPresence {
            if file.found.contains(display) || file.connected.contains(id) || file.shown.contains(id) {
                return .found(display)
            }
            return .missing(display)
        }
        return DetectionSummary(
            detectedAt: parseISO(file.detectedAt) ?? Date.distantPast,
            claude: presence("claude", display: "Claude Code"),
            codex: presence("codex", display: "Codex"),
            gemini: presence("gemini", display: "Gemini"),
            grok: presence("grok", display: "Grok"),
            local: presence("local", display: "Ollama"),
            node: file.nodeAvailable == false ? .missing("Node.js") : .found("Node.js"),
            python3: file.pythonAvailable == false ? .missing("Python 3") : .found("Python 3")
        )
    }

    private static func loadFile(_ url: URL) -> ProviderPreferencesFile? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProviderPreferencesFile.self, from: data)
    }

    private static func writeFile(_ file: ProviderPreferencesFile, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(file)
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func parseISO(_ value: String?) -> Date? {
        guard let value else { return nil }
        return UsageInsights.parseDate(value)
    }

    private static func bool(forKey key: String, defaultValue: Bool, defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }
}

extension Notification.Name {
    static let usageHUDProviderPreferencesDidChange = Notification.Name("UsageHUDProviderPreferencesDidChange")
    static let usageHUDOpenSettings = Notification.Name("UsageHUDOpenSettings")
    /// Opens the Activity window (the panel footer's "Activity").
    static let usageHUDOpenActivity = Notification.Name("UsageHUDOpenActivity")
}
