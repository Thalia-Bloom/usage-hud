import Foundation
import XCTest
@testable import CodexUsageHUD

final class ProviderHealthContractTests: XCTestCase {
    func testEmittedGrokNotSetUpDecodesQuietly() throws {
        let fm = FileManager.default
        let home = TestTemporaryDirectory.root.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let guardFile = home.appendingPathComponent("guard.cjs")
        try "require('https').get = () => { throw Error('network forbidden'); }; require('child_process').execFileSync = () => { throw Error('process forbidden'); };".write(to: guardFile, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "--require", guardFile.path, root.appendingPathComponent("bin/bloom-usage-write-grok").path]
        process.environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "HOME": home.path, "CFFIXED_USER_HOME": home.path,
            "GROK_HOME": home.appendingPathComponent(".grok").path,
            "CODEX_USAGE_HUD_STATE_DIR": home.appendingPathComponent(".codex-usage-hud").path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let data = try Data(contentsOf: home.appendingPathComponent(".codex-usage-hud/grok-usage.json"))
        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: data)
        XCTAssertEqual(snapshot.health?.isNotSetUp, true)
        XCTAssertEqual(snapshot.health?.isWarning, false)
        let freshness = UsageInsights.laneFreshness(for: snapshot)
        XCTAssertEqual(freshness.label, "not set up")
        XCTAssertFalse(freshness.needsAttention)
        XCTAssertFalse(headerHasHealthWarning(snapshot))
    }

    func testRealFailuresRemainWarnings() throws {
        for verdict in ["broken", "unauthorized", "invalid", "stale", "degraded"] {
            let data = try JSONSerialization.data(withJSONObject: ["provider":"grok", "health":["verdict":verdict]])
            let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: data)
            XCTAssertEqual(snapshot.health?.isWarning, true, verdict)
            XCTAssertTrue(UsageInsights.laneFreshness(for: snapshot).needsAttention, verdict)
        }
    }

    func testDetectionUsesConfigAndPriorEvidenceNotDirectory() {
        let home = URL(fileURLWithPath: "/synthetic-health-home")
        var probe = ToolDetection.Probe(home: home, fileExists: { $0.path.hasSuffix("/.grok") },
            isExecutable: { _ in false }, keychainItemExists: { _ in false }, nodeAvailable: true, python3Available: true)
        XCTAssertFalse(ToolDetection.detect(probe: probe).grok.isFound)
        probe.fileExists = { $0.lastPathComponent == "auth.json" }
        XCTAssertTrue(ToolDetection.detect(probe: probe).grok.isFound)
        probe.fileExists = { $0.lastPathComponent == "grok-usage.json" }
        probe.readData = { _ in Data(#"{"health":{"verdict":"not_set_up"},"windows":[]}"#.utf8) }
        XCTAssertFalse(ToolDetection.detect(probe: probe).grok.isFound)
        for raw in ["invalid", #"{"health":{"verdict":"broken"},"windows":[]}"#,
                    #"{"health":{"verdict":"not_set_up"},"windows":[{}]}"#] {
            probe.readData = { _ in Data(raw.utf8) }
            XCTAssertTrue(ToolDetection.detect(probe: probe).grok.isFound)
        }
        probe.readData = { _ in nil }
        XCTAssertTrue(ToolDetection.detect(probe: probe).grok.isFound)
    }

    func testFilesystemDetectionKeepsInvalidAuthEntryVisible() throws {
        let fm = FileManager.default
        let home = TestTemporaryDirectory.root.appendingPathComponent(UUID().uuidString)
        let grok = home.appendingPathComponent(".grok")
        try fm.createDirectory(at: grok, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let probe = ToolDetection.Probe.fileSystem(home: home)
        XCTAssertFalse(ToolDetection.detect(probe: probe).grok.isFound)
        let auth = grok.appendingPathComponent("auth.json")
        try fm.createSymbolicLink(atPath: auth.path, withDestinationPath: grok.appendingPathComponent("missing").path)
        XCTAssertTrue(ToolDetection.detect(probe: probe).grok.isFound)
    }

    func testActualLegacyUpgradeAndLocalRecordsAgreeWithDetection() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for record in [nil, "{", "", #"{"last_active_at":"2026-01-01T00:00:00Z","current_model_id":"grok-x"}"#] as [String?] {
            let home = TestTemporaryDirectory.root.appendingPathComponent(UUID().uuidString)
            try fm.createDirectory(at: home, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: home) }
            let session = home.appendingPathComponent(".grok/sessions/project/session")
            try fm.createDirectory(at: session, withIntermediateDirectories: true)
            if let record { try record.write(to: session.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8) }
            let probe = ToolDetection.Probe.fileSystem(home: home)
            XCTAssertEqual(ToolDetection.detect(probe: probe).grok.isFound, record != nil)
            let state = home.appendingPathComponent(".codex-usage-hud")
            func run(_ helper: String) throws -> UsageSnapshot {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["node", root.appendingPathComponent(helper).path]
                process.environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                    "HOME": home.path, "CFFIXED_USER_HOME": home.path, "GROK_HOME": home.appendingPathComponent(".grok").path,
                    "CODEX_USAGE_HUD_STATE_DIR": state.path,
                    "NODE_OPTIONS": "--require=" + root.appendingPathComponent("script/fixtures/health/guard.cjs").path]
                try process.run(); process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0)
                return try JSONDecoder().decode(UsageSnapshot.self, from: Data(contentsOf: state.appendingPathComponent("grok-usage.json")))
            }
            let legacy = try run("script/fixtures/health/legacy-grok-writer.cjs")
            XCTAssertEqual(legacy.health?.verdict, "broken")
            XCTAssertEqual(ToolDetection.detect(probe: probe).grok.isFound, record != nil)
            let snapshotFile = state.appendingPathComponent("grok-usage.json")
            let original = try Data(contentsOf: snapshotFile)
            var malformed = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            malformed["schemaVersion"] = true
            try JSONSerialization.data(withJSONObject: malformed).write(to: snapshotFile)
            XCTAssertTrue(ToolDetection.detect(probe: probe).grok.isFound)
            try original.write(to: snapshotFile)
            for _ in 0..<3 {
                let current = try run("bin/bloom-usage-write-grok")
                XCTAssertEqual(current.health?.verdict, record == nil ? "not_set_up" : "broken")
                XCTAssertEqual(ToolDetection.detect(probe: probe).grok.isFound, record != nil)
            }
            try "{".write(to: state.appendingPathComponent("grok-usage.json"), atomically: true, encoding: .utf8)
            for _ in 0..<3 {
                XCTAssertTrue(ToolDetection.detect(probe: probe).grok.isFound)
                XCTAssertEqual(try run("bin/bloom-usage-write-grok").health?.verdict, "broken")
                XCTAssertTrue(ToolDetection.detect(probe: probe).grok.isFound)
            }
            try "{}".write(to: home.appendingPathComponent(".grok/auth.json"), atomically: true, encoding: .utf8)
            XCTAssertTrue(ToolDetection.detect(probe: probe).grok.isFound)
        }
    }
}
