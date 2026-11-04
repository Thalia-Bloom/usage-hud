import XCTest
@testable import CodexUsageHUD

final class UpdateControllerTests: XCTestCase {
    private let appURL = URL(fileURLWithPath: "/Applications/Usage HUD.app")
    private let validInfo: [String: Any] = [
        "SUFeedURL": "https://hud.thaliabloom.com/appcast.xml",
        "SUPublicEDKey": "wKt3YF+sMCpboL1WDP5FkJmq7AFXuEFSIOsMNm0pVgs=", // gitleaks:allow -- public Sparkle verification key, identical to Info.plist
    ]

    private func availability(
        env: [String: String] = [:],
        url: URL? = nil,
        info: [String: Any]? = nil,
        testing: Bool = false
    ) -> UpdateController.Availability {
        UpdateController.availability(
            environment: env,
            bundleURL: url ?? appURL,
            infoDictionary: info ?? validInfo,
            isRunningTests: testing
        )
    }

    func testEnabledForShippedBundle() {
        XCTAssertEqual(availability(), .enabled)
    }

    func testInertInSnapshotAndProbeModes() {
        for key in UpdateController.oneShotModeKeys {
            XCTAssertNotEqual(availability(env: [key: "/tmp/out.png"]), .enabled, key)
        }
        // An empty value is not a mode switch.
        XCTAssertEqual(availability(env: ["CODEX_USAGE_HUD_SNAPSHOT": ""]), .enabled)
    }

    func testInertUnderTestsAndOptOut() {
        XCTAssertNotEqual(availability(testing: true), .enabled)
        XCTAssertNotEqual(availability(env: [UpdateController.disableKey: "1"]), .enabled)
        XCTAssertTrue(UpdateController.isRunningTests)
    }

    func testInertOutsideAppBundle() {
        let bare = URL(fileURLWithPath: "/Users/me/src/usage-hud/.build/release")
        XCTAssertEqual(availability(url: bare), .disabled("not running from a .app bundle"))
    }

    func testInertWithoutFeedOrKey() {
        XCTAssertNotEqual(availability(info: ["SUPublicEDKey": "abc"]), .enabled)
        XCTAssertNotEqual(availability(info: ["SUFeedURL": "https://hud.thaliabloom.com/appcast.xml"]), .enabled)
        XCTAssertNotEqual(availability(info: ["SUFeedURL": "", "SUPublicEDKey": "abc"]), .enabled)
    }

    @MainActor
    func testStartAndCheckAreNoOpsInTests() {
        UpdateController.shared.start()
        XCTAssertFalse(UpdateController.shared.isActive)
        // The menu item's notification must not crash or start anything.
        NotificationCenter.default.post(name: UpdateController.checkForUpdatesNotification, object: nil)
        UpdateController.shared.checkForUpdates()
        XCTAssertFalse(UpdateController.shared.isActive)
        XCTAssertEqual(UpdateController.checkForUpdatesNotification.rawValue, "usageHUDCheckForUpdates")
    }

    func testShippedInfoPlistConfiguresSparkle() throws {
        let plistURL = repoRoot.appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

        XCTAssertEqual(info["SUFeedURL"] as? String, "https://hud.thaliabloom.com/appcast.xml")
        let key = try XCTUnwrap(info["SUPublicEDKey"] as? String)
        XCTAssertEqual(Data(base64Encoded: key)?.count, 32, "SUPublicEDKey must be a base64 ed25519 public key")
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, false)
        XCTAssertEqual(info["SUScheduledCheckInterval"] as? Int, 86400)
        // Sparkle compares CFBundleVersion; it must stay a plain integer build number.
        let build = try XCTUnwrap(info["CFBundleVersion"] as? String)
        XCTAssertNotNil(Int(build), "CFBundleVersion must be an integer build number")
        XCTAssertEqual(availability(info: info), .enabled)
    }

    func testPublishedAppcastIsWellFormed() throws {
        let url = repoRoot.appendingPathComponent("site/public/appcast.xml")
        let doc = try XMLDocument(contentsOf: url, options: [])
        let root = try XCTUnwrap(doc.rootElement())
        XCTAssertEqual(root.name, "rss")
        let sparkleNS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
        XCTAssertEqual(root.namespace(forPrefix: "sparkle")?.stringValue, sparkleNS)
        let items = try doc.nodes(forXPath: "/rss/channel/item").compactMap { $0 as? XMLElement }
        var seen = Set<String>()
        for item in items {
            let version = try XCTUnwrap(item.elements(forLocalName: "version", uri: sparkleNS).first?.stringValue)
            XCTAssertNotNil(Int(version), "sparkle:version is the integer CFBundleVersion")
            XCTAssertTrue(seen.insert(version).inserted, "duplicate appcast item for build \(version)")
            let enclosure = try XCTUnwrap(item.elements(forName: "enclosure").first)
            let href = try XCTUnwrap(enclosure.attribute(forName: "url")?.stringValue)
            XCTAssertTrue(href.hasPrefix("https://github.com/Thalia-Bloom/usage-hud/releases/download/v"), href)
            XCTAssertFalse(enclosure.attribute(forLocalName: "edSignature", uri: sparkleNS)?.stringValue?.isEmpty ?? true)
            XCTAssertGreaterThan(Int(enclosure.attribute(forName: "length")?.stringValue ?? "") ?? 0, 0)
        }
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
