import Foundation

/// Marketing version and legal copy for About/Settings. The SPM executable
/// does not embed Info.plist, so the panel cannot rely on Bundle.main alone.
enum AppInfo {
    static let productName = "Usage HUD"
    static let marketingVersion = "1.3.4"
    static let buildNumber = "14"
    static let legalName = "Thalia Bloom"
    static let supportURL = URL(string: "https://hud.thaliabloom.com/support/")!
    static let tipURL = URL(string: "https://hud.thaliabloom.com/?source=app#tip")!

    static var versionLine: String { "\(productName) \(marketingVersion)" }
    static var supportLine: String { "Updates and support: \(supportURL.absoluteString)" }

    /// Prefer the app-bundle plist when running as CodexUsageHUD.app; fall back
    /// to the compile-time constant for `swift run` / snapshot binaries.
    static var resolvedMarketingVersion: String {
        let bundle = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        if let bundle, !bundle.isEmpty { return bundle }
        return marketingVersion
    }

    static var resolvedVersionLine: String { "\(productName) \(resolvedMarketingVersion)" }
}
