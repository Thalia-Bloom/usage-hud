import Foundation

/// Scripts copied into `Contents/Resources/bin/` by `make app`.
/// Keep in sync with `Resources/bundled-helpers.txt`.
enum BundledHelpers {
    static let scriptNames: [String] = [
        "bloom-budget-notify",
        "bloom-budget-update",
        "bloom-node",
        "bloom-usage-capture.sh",
        "bloom-usage-fetch-claude-official",
        "bloom-usage-statusline-tap",
        "bloom-usage-write-claude",
        "bloom-usage-write-codex",
        "bloom-usage-write-gemini-agy",
        "bloom-usage-write-grok",
        "codex-usage-doctor",
        "codex-usage-refresh",
        "codex-usage-write",
    ]

    /// Launch agents Set up loads for a zip-only buyer.
    static let coreLaunchdLabels: [String] = [
        "com.codexusagehud.app",
        "com.codexusagehud.codex-writer",
        "com.codexusagehud.claude-writer",
        "com.codexusagehud.grok-writer",
        "com.codexusagehud.refresh",
    ]

    static func bundledBinDirectory(bundle: Bundle = .main) -> URL? {
        if let override = ProcessInfo.processInfo.environment["CODEX_USAGE_HUD_BUNDLED_BIN"], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        let resourceBin = bundle.resourceURL?.appendingPathComponent("bin")
        if let resourceBin, FileManager.default.fileExists(atPath: resourceBin.path) {
            return resourceBin
        }
        return nil
    }

    static func bundledLaunchdDirectory(bundle: Bundle = .main) -> URL? {
        if let override = ProcessInfo.processInfo.environment["CODEX_USAGE_HUD_TEMPLATE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        let resourceLaunchd = bundle.resourceURL?.appendingPathComponent("launchd")
        if let resourceLaunchd, FileManager.default.fileExists(atPath: resourceLaunchd.path) {
            return resourceLaunchd
        }
        return nil
    }
}
