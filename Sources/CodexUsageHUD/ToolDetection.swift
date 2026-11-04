import Foundation
import Security
import Darwin
import CoreFoundation

enum ToolPresence: Equatable {
    case found(String)
    case missing(String)

    var isFound: Bool {
        if case .found = self { return true }
        return false
    }

    var reason: String {
        switch self {
        case .found(let reason), .missing(let reason):
            return reason
        }
    }
}

struct DetectionSummary: Equatable {
    var detectedAt: Date
    var claude: ToolPresence
    var codex: ToolPresence
    var gemini: ToolPresence
    var grok: ToolPresence
    var local: ToolPresence
    var node: ToolPresence
    var python3: ToolPresence

    static let customerOrder: [(id: String, displayName: String)] = [
        ("claude", "Claude Code"),
        ("codex", "Codex"),
        ("gemini", "Gemini"),
        ("grok", "Grok"),
        ("local", "Ollama"),
    ]

    func presence(for provider: String) -> ToolPresence {
        switch provider.lowercased() {
        case "claude": return claude
        case "codex": return codex
        case "gemini": return gemini
        case "grok": return grok
        case "local": return local
        default: return .missing("unknown provider")
        }
    }

    func isFound(_ provider: String) -> Bool {
        presence(for: provider).isFound
    }

    var foundDisplayNames: [String] {
        Self.customerOrder.compactMap { isFound($0.id) ? $0.displayName : nil }
    }

    var missingDisplayNames: [String] {
        Self.customerOrder.compactMap { isFound($0.id) ? nil : $0.displayName }
    }

    var foundLine: String? {
        let names = foundDisplayNames
        guard !names.isEmpty else { return nil }
        return "Found: \(names.joined(separator: ", "))"
    }

    var missingLine: String? {
        let names = missingDisplayNames
        guard !names.isEmpty else { return nil }
        return "Not found: \(names.joined(separator: ", "))"
    }

    /// Names only the Node-only lanes this Mac has (both when no coding tool
    /// was found yet, so the buyer still learns what Node.js is for).
    var runtimeNote: String? {
        let codingTools = foundCustomerIds.filter { ["claude", "codex", "gemini", "grok"].contains($0) }
        let nodeLanes = codingTools.isEmpty
            ? Self.nodeOnlyLanes.map(\.name)
            : Self.nodeOnlyLanes.filter { codingTools.contains($0.id) }.map(\.name)
        return Self.runtimeNote(nodeAvailable: node.isFound, pythonAvailable: python3.isFound, nodeLanes: nodeLanes)
    }

    static let nodeOnlyLanes: [(id: String, name: String)] = [("gemini", "Gemini"), ("grok", "Grok")]

    var foundCustomerIds: [String] {
        Self.customerOrder.compactMap { isFound($0.id) ? $0.id : nil }
    }

    /// Claude and Codex no longer need either runtime: the app reads them
    /// itself when their LaunchAgents cannot run. Python is not needed by any
    /// lane, so only a missing Node.js earns a note.
    static func runtimeNote(
        nodeAvailable: Bool,
        pythonAvailable: Bool,
        nodeLanes: [String] = nodeOnlyLanes.map(\.name)
    ) -> String? {
        guard !nodeAvailable, !nodeLanes.isEmpty else { return nil }
        let verb = nodeLanes.count == 1 ? "needs" : "need"
        return "\(nodeLanes.joined(separator: " and ")) \(verb) Node.js. \(RuntimeDependencies.nodeInstallHint)."
    }
}

enum ToolDetection {
    static let claudeKeychainService = "Claude Code-credentials"

    struct Probe {
        var home: URL
        var fileExists: (URL) -> Bool
        var isExecutable: (URL) -> Bool
        var keychainItemExists: (String) -> Bool
        var nodeAvailable: Bool
        var python3Available: Bool
        var readData: (URL) -> Data? = { try? Data(contentsOf: $0) }
        var grokHome: URL? = nil
        var stateDirectory: URL? = nil
        var configurationEntryExists: ((URL) -> Bool)? = nil

        static func live(
            home: URL = UsagePaths.home,
            fileManager: FileManager = .default
        ) -> Probe {
            Probe(
                home: home,
                fileExists: { fileManager.fileExists(atPath: $0.path) },
                isExecutable: { fileManager.isExecutableFile(atPath: $0.path) },
                keychainItemExists: { ToolDetection.keychainItemExists(service: $0) },
                nodeAvailable: RuntimeDependencies.nodeAvailable,
                python3Available: RuntimeDependencies.python3Available,
                grokHome: ProcessInfo.processInfo.environment["GROK_HOME"].map { URL(fileURLWithPath: $0) },
                stateDirectory: UsagePaths.stateDirectory,
                configurationEntryExists: { ToolDetection.configurationEntryExists($0, fileManager: fileManager) }
            )
        }

        static func fileSystem(
            home: URL,
            fileManager: FileManager = .default,
            keychainItemExists: @escaping (String) -> Bool = { _ in false },
            nodeAvailable: Bool = true,
            python3Available: Bool = true
        ) -> Probe {
            Probe(
                home: home,
                fileExists: { fileManager.fileExists(atPath: $0.path) },
                isExecutable: { fileManager.isExecutableFile(atPath: $0.path) },
                keychainItemExists: keychainItemExists,
                nodeAvailable: nodeAvailable,
                python3Available: python3Available,
                configurationEntryExists: { ToolDetection.configurationEntryExists($0, fileManager: fileManager) }
            )
        }
    }

    /// Inspect the entry, not its contents/target. Inaccessible or dangling
    /// configuration is repair evidence; only a missing entry means no setup.
    private static func configurationEntryExists(_ url: URL, fileManager: FileManager) -> Bool {
        do {
            _ = try fileManager.attributesOfItem(atPath: url.path)
            return true
        } catch {
            let error = error as NSError
            return !(error.domain == NSCocoaErrorDomain &&
                [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code))
        }
    }

    static func executableSearchDirectories(home: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            home.appendingPathComponent(".npm-global/bin"),
            home.appendingPathComponent(".local/bin"),
        ]
    }

    /// Attributes-only Keychain lookup. Never requests `kSecReturnData`.
    static func keychainAttributeQuery(service: String = claudeKeychainService) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
    }

    static func keychainItemExists(service: String = claudeKeychainService) -> Bool {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(keychainAttributeQuery(service: service) as CFDictionary, &item)
        return status == errSecSuccess
    }

    static func detect(probe: Probe, now: Date = Date()) -> DetectionSummary {
        DetectionSummary(
            detectedAt: now,
            claude: detectClaude(probe: probe),
            codex: detectCodex(probe: probe),
            gemini: detectGemini(probe: probe),
            grok: detectGrok(probe: probe),
            local: detectLocal(probe: probe),
            node: probe.nodeAvailable ? .found("Node.js") : .missing("Node.js is not installed"),
            python3: probe.python3Available ? .found("Python 3") : .missing("Python 3 is not installed")
        )
    }

    static func detect() -> DetectionSummary {
        detect(probe: .live())
    }

    private static func detectClaude(probe: Probe) -> ToolPresence {
        let dir = probe.home.appendingPathComponent(".claude", isDirectory: true)
        let credentials = dir.appendingPathComponent(".credentials.json")
        let hasDir = probe.fileExists(dir)
        let hasCredentials = probe.fileExists(credentials)
        let hasKeychain = probe.keychainItemExists(claudeKeychainService)
        if hasDir && (hasCredentials || hasKeychain) {
            if hasCredentials {
                return .found("Claude Code credentials file")
            }
            return .found("Claude Code Keychain item")
        }
        if hasDir {
            return .missing("Claude Code is present but not signed in")
        }
        return .missing("Claude Code is not installed")
    }

    private static func detectCodex(probe: Probe) -> ToolPresence {
        let sessions = probe.home.appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        if probe.fileExists(sessions) {
            return .found("Codex session logs")
        }
        if executableExists("codex", probe: probe) {
            return .found("Codex executable")
        }
        return .missing("Codex is not installed")
    }

    private static func detectGemini(probe: Probe) -> ToolPresence {
        // The Gemini lane reads the Antigravity CLI's /quota panel; the Gemini
        // CLI alone has no quota source this app can read.
        if executableExists("agy", probe: probe) {
            return .found("Antigravity executable")
        }
        let dir = probe.home.appendingPathComponent(".gemini", isDirectory: true)
        if probe.fileExists(dir) || executableExists("gemini", probe: probe) {
            return .missing("Gemini usage needs the Antigravity CLI (agy)")
        }
        return .missing("Gemini is not installed")
    }

    private static func detectGrok(probe: Probe) -> ToolPresence {
        let auth = (probe.grokHome ?? probe.home.appendingPathComponent(".grok", isDirectory: true))
            .appendingPathComponent("auth.json")
        if (probe.configurationEntryExists ?? probe.fileExists)(auth) {
            return .found("Grok configuration (sign-in may need repair)")
        }
        if grokSessionEvidence(auth.deletingLastPathComponent().appendingPathComponent("sessions")) {
            return .found("Grok local session records (sign-in may need repair)")
        }
        let snapshot = (probe.stateDirectory ?? probe.home.appendingPathComponent(".codex-usage-hud"))
            .appendingPathComponent("grok-usage.json")
        if (probe.configurationEntryExists ?? probe.fileExists)(snapshot) {
            let raw = probe.readData(snapshot).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let health = raw?["health"] as? [String: Any]
            let windows = raw?["windows"] as? [Any]
            let legacySchema = (raw?["schemaVersion"] as? NSNumber).map {
                CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue == 1
            } ?? false
            let hasPrior = ["official", "week", "currentSession", "providerHealth", "officialUsageStatus", "extraUsage"].contains {
                raw?[$0] != nil && !(raw?[$0] is NSNull)
            }
            let quiet = health?["verdict"] as? String == "not_set_up"
                || (health?["verdict"] as? String == "broken"
                    && legacySchema && raw?["provider"] as? String == "grok"
                    && raw?["source"] as? String == "grok cli billing + local sessions"
                    && raw?["sourceKind"] as? String == "local_session_log" && raw?["confidence"] as? String == "low"
                    && health?["reason"] as? String == "No grok CLI auth found (~/.grok/auth.json). Run `grok login`.")
            if !quiet || windows?.isEmpty != true || hasPrior {
                return .found("Grok prior reading (may need repair)")
            }
        }
        return .missing("Grok is not set up")
    }

    // Same metadata-only predicate and 500-entry budget as writer/doctor.
    // No summary contents are read. Uncertain traversal stays actionable.
    private static func grokSessionEvidence(_ root: URL) -> Bool {
        var remaining = 500
        func visit(_ directory: URL, depth: Int) -> Bool {
            guard let stream = opendir(directory.path) else { return errno != ENOENT }
            defer { closedir(stream) }
            errno = 0
            while let entry = readdir(stream) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                remaining -= 1
                if remaining < 0 { return true }
                if depth == 2 {
                    if name == "summary.json" { return true }
                } else {
                    if entry.pointee.d_type == DT_LNK { return true }
                    if entry.pointee.d_type == DT_DIR && visit(directory.appendingPathComponent(name), depth: depth + 1) { return true }
                    if entry.pointee.d_type == DT_UNKNOWN { return true }
                }
                errno = 0
            }
            return errno != 0
        }
        return visit(root, depth: 0)
    }

    private static func detectLocal(probe: Probe) -> ToolPresence {
        let dir = probe.home.appendingPathComponent(".ollama", isDirectory: true)
        if probe.fileExists(dir) {
            return .found("Ollama data")
        }
        let app = URL(fileURLWithPath: "/Applications/Ollama.app")
        if probe.fileExists(app) {
            return .found("Ollama app")
        }
        if executableExists("ollama", probe: probe) {
            return .found("Ollama executable")
        }
        return .missing("Ollama is not installed")
    }

    private static func executableExists(_ name: String, probe: Probe) -> Bool {
        executableSearchDirectories(home: probe.home).contains { dir in
            probe.isExecutable(dir.appendingPathComponent(name))
        }
    }
}
