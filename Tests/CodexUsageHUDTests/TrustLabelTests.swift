import XCTest
@testable import CodexUsageHUD

final class TrustLabelTests: XCTestCase {

    // MARK: - Central: stale/historical must never read as live "Official"

    func testStaleOfficialReadingNeverDisplaysAsLiveOfficial() throws {
        let now = try XCTUnwrap(UsageInsights.parseDate("2026-05-10T12:00:00Z"))
        let snapshot = UsageSnapshot(
            provider: "claude",
            confidence: "official",
            week: UsageSnapshot.WindowMetric(usedPct: 50, eventAt: "2026-05-08T12:00:00Z"),
            contributors: [], skills: [], subagents: []
        )

        let trust = UsageInsights.laneTrust(for: snapshot, now: now)
        XCTAssertFalse(trust.isLive)
        XCTAssertNotEqual(trust.chipLabel, "Official")
        XCTAssertEqual(trust.chipLabel, "Official · old")
    }

    func testHistoricalReadingNeverDisplaysAsLiveOfficial() throws {
        let now = try XCTUnwrap(UsageInsights.parseDate("2026-05-10T12:00:00Z"))
        let snapshot = UsageSnapshot(
            provider: "claude",
            confidence: "official",
            week: UsageSnapshot.WindowMetric(usedPct: 50, eventAt: "2026-05-10T11:55:00Z"),
            contributors: [], skills: [], subagents: []
        )

        let trust = UsageInsights.laneTrust(for: snapshot, historical: true, now: now)
        XCTAssertFalse(trust.isLive)
        XCTAssertNotEqual(trust.chipLabel, "Official")
    }

    // MARK: - Confidence mapping

    func testConfidenceMapsDeclaredLevelsToLabels() throws {
        func snapshot(_ confidence: String) -> UsageSnapshot {
            UsageSnapshot(provider: "claude", confidence: confidence, contributors: [], skills: [], subagents: [])
        }

        let cases: [(String, level: String, label: String, rank: Int)] = [
            ("official", "official", "Official", 0),
            ("very_high", "official", "Official", 0),
            ("high", "high", "High", 1),
            ("medium", "medium", "Estimated", 2),
            ("estimated", "medium", "Estimated", 2),
            ("derived", "medium", "Estimated", 2),
            ("manual", "manual", "Manual", 3),
            ("some-unrecognized-value", "unknown", "Unknown", 3)
        ]

        for testCase in cases {
            let confidence = UsageInsights.confidence(snapshot(testCase.0))
            XCTAssertEqual(confidence.level, testCase.level, "level for \(testCase.0)")
            XCTAssertEqual(confidence.label, testCase.label, "label for \(testCase.0)")
            XCTAssertEqual(confidence.rank, testCase.rank, "rank for \(testCase.0)")
        }
    }

    func testConfidenceFallsBackToInferredWhenUndeclared() throws {
        let officialBySourceKind = UsageSnapshot(
            provider: "claude", sourceKind: "official_api", contributors: [], skills: [], subagents: []
        )
        XCTAssertEqual(UsageInsights.confidence(officialBySourceKind).level, "official")

        let highBySourceKind = UsageSnapshot(
            provider: "codex", sourceKind: "local_session_log", contributors: [], skills: [], subagents: []
        )
        XCTAssertEqual(UsageInsights.confidence(highBySourceKind).level, "high")

        let mediumBySource = UsageSnapshot(
            provider: "claude", source: "claude token tracker", contributors: [], skills: [], subagents: []
        )
        XCTAssertEqual(UsageInsights.confidence(mediumBySource).level, "medium")

        let unknown = UsageSnapshot(
            provider: "claude", source: "mystery", sourceKind: "made up", contributors: [], skills: [], subagents: []
        )
        XCTAssertEqual(UsageInsights.confidence(unknown).level, "unknown")
    }

    func testConfidenceNoteIsCarriedIntoTrustNoteAndHelp() throws {
        let now = try XCTUnwrap(UsageInsights.parseDate("2026-05-10T12:00:00Z"))
        let snapshot = UsageSnapshot(
            provider: "claude",
            confidence: "high",
            confidenceNote: "Custom note from the writer.",
            updatedAt: "2026-05-10T11:00:00Z",
            capturedAt: "2026-05-10T11:00:00Z",
            contributors: [], skills: [], subagents: []
        )

        let trust = UsageInsights.laneTrust(for: snapshot, now: now)
        XCTAssertEqual(trust.note, "Custom note from the writer.")
        XCTAssertTrue(trust.help.contains("Custom note from the writer."))
    }

    func testConfidenceDefaultNoteWhenWriterSetNone() throws {
        let now = try XCTUnwrap(UsageInsights.parseDate("2026-05-10T12:00:00Z"))
        let snapshot = UsageSnapshot(
            provider: "claude",
            confidence: "high",
            updatedAt: "2026-05-10T11:00:00Z",
            capturedAt: "2026-05-10T11:00:00Z",
            contributors: [], skills: [], subagents: []
        )

        let trust = UsageInsights.laneTrust(for: snapshot, now: now)
        XCTAssertFalse(trust.note.isEmpty)
        XCTAssertTrue(trust.help.contains(trust.note))
    }

    // MARK: - Chip rules

    func testLiveOfficialReadingShowsBareOfficialChip() throws {
        let now = try XCTUnwrap(UsageInsights.parseDate("2026-05-10T12:00:00Z"))
        let snapshot = UsageSnapshot(
            provider: "claude",
            confidence: "official",
            currentSession: UsageSnapshot.WindowMetric(usedPct: 20, eventAt: "2026-05-10T11:55:00Z"),
            contributors: [], skills: [], subagents: []
        )

        let trust = UsageInsights.laneTrust(for: snapshot, now: now)
        XCTAssertTrue(trust.isLive)
        XCTAssertEqual(trust.chipLabel, "Official")
    }

    func testUnknownChipIsNeverSuffixedWithOld() throws {
        let now = try XCTUnwrap(UsageInsights.parseDate("2026-05-10T12:00:00Z"))
        let snapshot = UsageSnapshot(
            provider: "claude",
            confidence: "some-unrecognized-value",
            updatedAt: "2026-05-01T00:00:00Z",
            capturedAt: "2026-05-01T00:00:00Z",
            contributors: [], skills: [], subagents: []
        )

        let trust = UsageInsights.laneTrust(for: snapshot, now: now)
        XCTAssertFalse(trust.isLive)
        XCTAssertEqual(trust.chipLabel, "Unknown")
    }

    func testMissingSnapshotReportsUnknownNotOfficial() throws {
        let trust = UsageInsights.laneTrust(for: nil)
        XCTAssertEqual(trust.level, "missing")
        XCTAssertEqual(trust.chipLabel, "Unknown")
        XCTAssertFalse(trust.isLive)
    }

    // MARK: - Header honesty

    func testTrustCaveatIsSilentWhenEveryLaneIsLiveAndTrusted() throws {
        let now = try XCTUnwrap(UsageInsights.parseDate("2026-05-10T12:00:00Z"))
        let claude = UsageSnapshot(
            provider: "claude",
            confidence: "official",
            currentSession: UsageSnapshot.WindowMetric(usedPct: 10, eventAt: "2026-05-10T11:55:00Z"),
            contributors: [], skills: [], subagents: []
        )
        let codex = UsageSnapshot(
            provider: "codex",
            confidence: "high",
            currentSession: UsageSnapshot.WindowMetric(usedPct: 15, eventAt: "2026-05-10T11:55:00Z"),
            contributors: [], skills: [], subagents: []
        )

        XCTAssertNil(UsageInsights.trustCaveat(snapshots: [claude, codex], now: now))
    }

    func testTrustCaveatNamesStaleLane() throws {
        let now = try XCTUnwrap(UsageInsights.parseDate("2026-05-10T12:00:00Z"))
        let codex = UsageSnapshot(
            provider: "codex",
            confidence: "high",
            currentSession: UsageSnapshot.WindowMetric(usedPct: 15, eventAt: "2026-05-10T11:55:00Z"),
            contributors: [], skills: [], subagents: []
        )
        let claude = UsageSnapshot(
            provider: "claude",
            confidence: "official",
            week: UsageSnapshot.WindowMetric(usedPct: 50, eventAt: "2026-05-08T12:00:00Z"),
            contributors: [], skills: [], subagents: []
        )

        let caveat = try XCTUnwrap(UsageInsights.trustCaveat(snapshots: [codex, claude], now: now))
        XCTAssertTrue(caveat.contains(UsageInsights.label(for: "claude")))
    }

    func testTrustCaveatSkipsStaleManualLane() throws {
        let now = try XCTUnwrap(UsageInsights.parseDate("2026-05-10T12:00:00Z"))
        let codex = UsageSnapshot(
            provider: "codex",
            confidence: "official",
            currentSession: UsageSnapshot.WindowMetric(usedPct: 15, eventAt: "2026-05-10T11:55:00Z"),
            contributors: [], skills: [], subagents: []
        )
        let manual = UsageSnapshot(
            provider: "grok",
            sourceKind: "native_ui_observation",
            confidence: "unknown",
            week: UsageSnapshot.WindowMetric(usedPct: 46, eventAt: "2026-05-04T12:00:00Z"),
            contributors: [], skills: [], subagents: []
        )

        let caveat = UsageInsights.trustCaveat(snapshots: [codex, manual], now: now) ?? ""
        XCTAssertFalse(caveat.contains(UsageInsights.label(for: "grok")))
    }

    func testTrustCaveatNamesEstimatedLane() throws {
        let now = try XCTUnwrap(UsageInsights.parseDate("2026-05-10T12:00:00Z"))
        let codex = UsageSnapshot(
            provider: "codex",
            confidence: "official",
            currentSession: UsageSnapshot.WindowMetric(usedPct: 15, eventAt: "2026-05-10T11:55:00Z"),
            contributors: [], skills: [], subagents: []
        )
        let claude = UsageSnapshot(
            provider: "claude",
            confidence: "medium",
            currentSession: UsageSnapshot.WindowMetric(usedPct: 30, eventAt: "2026-05-10T11:55:00Z"),
            contributors: [], skills: [], subagents: []
        )

        let caveat = try XCTUnwrap(UsageInsights.trustCaveat(snapshots: [codex, claude], now: now))
        XCTAssertTrue(caveat.contains(UsageInsights.label(for: "claude")))
    }

    // MARK: - displayTrust: the chip describes the number, not just the source

    func testDerivedIdleZeroDoesNotWearTheProvidersOfficialChip() throws {
        let now = try XCTUnwrap(UsageInsights.parseDate("2026-05-10T12:00:00Z"))
        // An official, freshly-checked lane that simply had no runs. The panel
        // shows 0% because nothing ran, but the provider never reported a 0%.
        let snapshot = UsageSnapshot(
            provider: "codex",
            confidence: "official",
            updatedAt: "2026-05-10T11:58:00Z",
            currentSession: UsageSnapshot.WindowMetric(usedPct: 4, eventAt: "2026-05-10T11:58:00Z"),
            contributors: [], skills: [], subagents: []
        )

        let source = UsageInsights.displayTrust(for: snapshot, now: now)
        XCTAssertEqual(source.chipLabel, "Official")

        let derived = UsageInsights.displayTrust(for: snapshot, derived: true, now: now)
        XCTAssertEqual(derived.level, "medium")
        XCTAssertEqual(derived.label, "Estimated")
        XCTAssertNotEqual(derived.chipLabel, "Official")
        XCTAssertTrue(derived.note.contains("idle"))
    }

    func testDerivedFlagNeverUpgradesAnAlreadyWeakerReading() throws {
        let now = try XCTUnwrap(UsageInsights.parseDate("2026-05-10T12:00:00Z"))
        let snapshot = UsageSnapshot(
            provider: "grok",
            updatedAt: "2026-05-10T11:58:00Z",
            currentSession: UsageSnapshot.WindowMetric(usedPct: 4, eventAt: "2026-05-10T11:58:00Z"),
            contributors: [], skills: [], subagents: []
        )

        let derived = UsageInsights.displayTrust(for: snapshot, derived: true, now: now)
        XCTAssertEqual(derived.level, "unknown")
        XCTAssertEqual(derived.chipLabel, "Unknown")
    }

    func testDerivedReadingStillLosesLiveClaimWhenStale() throws {
        let now = try XCTUnwrap(UsageInsights.parseDate("2026-05-10T12:00:00Z"))
        let snapshot = UsageSnapshot(
            provider: "codex",
            confidence: "official",
            updatedAt: "2026-05-07T12:00:00Z",
            currentSession: UsageSnapshot.WindowMetric(usedPct: 4, eventAt: "2026-05-07T12:00:00Z"),
            contributors: [], skills: [], subagents: []
        )

        let derived = UsageInsights.displayTrust(for: snapshot, derived: true, now: now)
        XCTAssertFalse(derived.isLive)
        XCTAssertNotEqual(derived.chipLabel, "Official")
    }
}
