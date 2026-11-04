import SwiftUI
import XCTest
@testable import CodexUsageHUD

/// One truth model for freshness: the header pill, the lane row, its source
/// tag, the detail card and the verdict must never disagree about the same
/// reading. These pin the rules the "unknowns" render used to break
/// (header "live", row "measured · old", card "measured · live", GO).
final class PanelTruthTests: XCTestCase {
    private let now = UsageInsights.parseDate("2026-09-30T19:00:00Z")!
    private func iso(_ minutesAgo: Double) -> String {
        now.addingTimeInterval(-minutesAgo * 60).ISO8601Format()
    }

    /// Writer checked in just now, but the 5-hour window it carries is from
    /// three hours ago.
    private func claudeWithOldWindow() -> UsageSnapshot {
        UsageSnapshot(provider: "claude", sourceKind: "official_api", confidence: "high",
                      updatedAt: iso(0), capturedAt: iso(0), eventAt: iso(200),
                      currentSession: .init(usedPct: 45, resetAt: now.addingTimeInterval(2.5 * 3600).ISO8601Format()),
                      contributors: [], skills: [], subagents: [])
    }

    private func live(_ provider: String, used: Double = 20) -> UsageSnapshot {
        UsageSnapshot(provider: provider, confidence: "official",
                      updatedAt: iso(1), capturedAt: iso(1), eventAt: iso(1),
                      week: .init(usedPct: used, resetAt: now.addingTimeInterval(3 * 86_400).ISO8601Format()),
                      contributors: [], skills: [], subagents: [])
    }

    // MARK: - One clock

    func testOldWindowIsOldEverywhereEvenWhenCaptureIsFresh() {
        let snap = claudeWithOldWindow()
        let fresh = UsageInsights.laneFreshness(for: snap, now: now)
        XCTAssertEqual(fresh.state, .old)
        XCTAssertEqual(fresh.ageShort, "3h")
        XCTAssertEqual(fresh.note, "updated 3h ago")

        // Row tag and detail card header read the same trust.
        let trust = UsageInsights.laneTrust(for: snap, now: now)
        XCTAssertFalse(trust.isLive)
        XCTAssertEqual(trust.tagText, "official · old")

        // Header names it instead of saying "live".
        let header = HeaderStatus.make(lanes: [.init(name: "Claude", freshness: fresh),
                                               .init(name: "Codex", freshness: UsageInsights.laneFreshness(for: live("codex"), now: now))])
        XCTAssertEqual(header.text, "Claude · old")
        XCTAssertEqual(header.tone, .attention)
    }

    func testGoNeverSitsOnAnOldWindow() {
        let reading = HeroVerdict.reading(for: claudeWithOldWindow(), now: now)
        XCTAssertFalse(reading.fresh)
        XCTAssertEqual(reading.why, "reading is 3h old")
        let verdict = HeroVerdict.resolve(mode: "green", laneName: "Claude", readingFresh: reading.fresh,
                                          paceStatus: "ON PACE", staleReason: reading.why)
        XCTAssertEqual(verdict, .init(mode: "check", tagline: "Claude: reading is 3h old"))
    }

    func testGoNeedsAFreshCheckInToo() {
        let snap = UsageSnapshot(provider: "claude", confidence: "official",
                                 updatedAt: iso(40), capturedAt: iso(40), eventAt: iso(40),
                                 week: .init(usedPct: 10), contributors: [], skills: [], subagents: [])
        let reading = HeroVerdict.reading(for: snap, now: now)
        XCTAssertFalse(reading.fresh)
        XCTAssertEqual(reading.why, "reading is 40m old")
    }

    func testLiveReadingCarriesGo() {
        let reading = HeroVerdict.reading(for: live("claude"), now: now)
        XCTAssertTrue(reading.fresh)
        XCTAssertNil(reading.why)
        XCTAssertEqual(HeroVerdict.resolve(mode: "green", laneName: "Claude", readingFresh: true, paceStatus: "ON PACE").mode, "green")
    }

    func testWeeklyReadingInsideItsCadenceIsRecentNotOld() {
        // Gemini's quota is re-read every few hours by design.
        let gemini = UsageSnapshot(provider: "gemini", sourceKind: "official_interactive", confidence: "official",
                                   updatedAt: iso(90), capturedAt: iso(90), eventAt: iso(90),
                                   week: .init(usedPct: 40), contributors: [], skills: [], subagents: [])
        let fresh = UsageInsights.laneFreshness(for: gemini, now: now)
        XCTAssertEqual(fresh.state, .recent)
        XCTAssertEqual(fresh.label, "updated 1h ago")
        XCTAssertFalse(fresh.needsAttention)
        XCTAssertTrue(UsageInsights.laneTrust(for: gemini, now: now).isLive)

        let header = HeaderStatus.make(lanes: [.init(name: "Gemini", freshness: fresh),
                                               .init(name: "Claude", freshness: UsageInsights.laneFreshness(for: live("claude"), now: now))])
        XCTAssertEqual(header.text, "Gemini · updated 1h ago")
        XCTAssertEqual(header.tone, .recent)
    }

    func testFiveHourWindowGoesOldSoonerThanAWeeklyOne() {
        let session = UsageSnapshot(provider: "codex", confidence: "high", capturedAt: iso(150), eventAt: iso(150),
                                    currentSession: .init(usedPct: 30), contributors: [], skills: [], subagents: [])
        let weekly = UsageSnapshot(provider: "codex", confidence: "high", capturedAt: iso(150), eventAt: iso(150),
                                   week: .init(usedPct: 30), contributors: [], skills: [], subagents: [])
        XCTAssertEqual(UsageInsights.laneFreshness(for: session, now: now).state, .old)
        XCTAssertEqual(UsageInsights.laneFreshness(for: weekly, now: now).state, .recent)
    }

    func testHeaderIsLiveOnlyWhenEveryLaneIsLive() {
        let lanes = ["claude", "codex"].map {
            HeaderStatus.Lane(name: UsageInsights.label(for: $0), freshness: UsageInsights.laneFreshness(for: live($0), now: now))
        }
        XCTAssertEqual(HeaderStatus.make(lanes: lanes).text, "live")
        XCTAssertEqual(HeaderStatus.make(lanes: []).text, "not connected")
    }

    func testHeaderCountsSeveralOldLanes() {
        let old = LaneFreshness(state: .old, age: 4 * 3600)
        let header = HeaderStatus.make(lanes: [.init(name: "Claude", freshness: old), .init(name: "Codex", freshness: old)])
        XCTAssertEqual(header.text, "2 lanes old")
        XCTAssertTrue(header.help.contains("Claude"))
        XCTAssertTrue(header.help.contains("Codex"))
    }

    // MARK: - Writer health shows on the row, not just the header

    func testWriterStaleHealthMakesTheRowOldToo() {
        var grok = live("grok")
        grok.health = .init(verdict: "stale", reason: "Token expired.", checkedAt: iso(0))
        let fresh = UsageInsights.laneFreshness(for: grok, now: now)
        XCTAssertEqual(fresh.state, .old)
        XCTAssertEqual(fresh.note, "not refreshing")
        XCTAssertEqual(fresh.issueDetail, "Token expired.")
        XCTAssertFalse(UsageInsights.laneTrust(for: grok, now: now).isLive)
        XCTAssertEqual(HeaderStatus.make(lanes: [.init(name: "Grok", freshness: fresh)]).text, "Grok · old")
        XCTAssertFalse(HeroVerdict.reading(for: grok, now: now).fresh)
    }

    func testRevokedSignInIsAnIssueWhileLiveNumbersStayLive() {
        var claude = live("claude")
        claude.officialUsageStatus = .init(status: "unauthorized", updatedAt: iso(0))
        let fresh = UsageInsights.laneFreshness(for: claude, now: now)
        XCTAssertEqual(fresh.state, .live)
        XCTAssertEqual(fresh.issue, "sign in again")
        XCTAssertTrue(fresh.needsAttention)
        XCTAssertTrue(UsageInsights.laneTrust(for: claude, now: now).isLive)
        XCTAssertEqual(HeaderStatus.make(lanes: [.init(name: "Claude", freshness: fresh)]).text, "Claude · sign in again")
    }

    func testExpiredSignInSaysSignInAgainEvenWhenTheReaderGoesAmber() {
        // What the in-app Claude reader writes for a 401 (seen on a clean VM).
        var claude = live("claude")
        claude.health = .init(verdict: "degraded", reason: "Claude Code login token is expired or revoked.", checkedAt: iso(0))
        claude.officialUsageStatus = .init(status: "unauthorized", updatedAt: iso(0))
        let fresh = UsageInsights.laneFreshness(for: claude, now: now)
        XCTAssertEqual(fresh.state, .old)
        XCTAssertEqual(fresh.issue, "sign in again")
        XCTAssertEqual(fresh.issueDetail, "Claude Code login token is expired or revoked.")
        XCTAssertEqual(HeaderStatus.make(lanes: [.init(name: "Claude", freshness: fresh)]).text, "Claude · sign in again")
    }

    func testLocalTokenCountIsAlwaysCurrent() {
        let local = UsageSnapshot(provider: "local", sourceKind: "local_runtime_log", confidence: "high",
                                  capturedAt: iso(3 * 24 * 60), contributors: [], skills: [], subagents: [])
        XCTAssertEqual(UsageInsights.laneFreshness(for: local, now: now).state, .live)
    }

    // MARK: - Label matches the source

    func testHighConfidenceFromAnOfficialSourceReadsOfficial() {
        for kind in ["official_api", "official_interactive", "official_app_server"] {
            let snap = UsageSnapshot(provider: "codex", sourceKind: kind, confidence: "high",
                                     contributors: [], skills: [], subagents: [])
            XCTAssertEqual(UsageInsights.confidence(snap).level, "official", kind)
            XCTAssertTrue(UsageInsights.plainSource(snap).hasPrefix("Official"), kind)
        }
        let local = UsageSnapshot(provider: "codex", sourceKind: "local_session_log", confidence: "high",
                                  contributors: [], skills: [], subagents: [])
        XCTAssertEqual(UsageInsights.confidence(local).level, "high")
        XCTAssertEqual(UsageInsights.laneTrust(for: local).word, "measured")
        // A writer that declared a weaker level keeps it.
        let estimated = UsageSnapshot(provider: "codex", sourceKind: "official_api", confidence: "medium",
                                      contributors: [], skills: [], subagents: [])
        XCTAssertEqual(UsageInsights.confidence(estimated).level, "medium")
    }

    func testSourceHelpIsPlain() {
        let help = UsageInsights.sourceHelp(claudeWithOldWindow(), now: now)
        XCTAssertTrue(help.contains("Official usage API"))
        XCTAssertTrue(help.contains("3h old"))
        XCTAssertFalse(help.contains("rate limit"))
    }

    func testCaveatSkipsTheLaneTheVerdictAlreadyNames() {
        let snaps = [claudeWithOldWindow(), live("codex")]
        let all = try? XCTUnwrap(UsageInsights.trustCaveat(snapshots: snaps, now: now))
        XCTAssertEqual(all, "Claude's reading is old.")
        XCTAssertNil(UsageInsights.trustCaveat(snapshots: snaps, excluding: ["claude"], now: now))
    }

    // MARK: - Fable uses the same words

    func testFableFreshnessUsesTheSharedVocabulary() {
        let old = FableDisplay.make(week: .init(usedPct: 37, capturedAt: iso(3 * 24 * 60)), expired: false, now: now)
        XCTAssertEqual(old.freshness?.state, .old)
        XCTAssertEqual(old.trust.tagText, "official · old")
        XCTAssertTrue(old.subline.contains("updated 3d ago"))

        let fresh = FableDisplay.make(week: .init(usedPct: 37, capturedAt: iso(4)), expired: false, now: now)
        XCTAssertEqual(fresh.freshness?.state, .live)
        XCTAssertEqual(fresh.trust.tagText, "official")

        // No stamp of its own: it rides on the Claude row, claims nothing.
        XCTAssertNil(FableDisplay.make(week: .init(usedPct: 37), expired: false, now: now).freshness)
    }

    // MARK: - Plain words

    func testRoomStatusIsPlainEnglish() {
        let snap = UsageSnapshot(provider: "codex", capturedAt: iso(0),
                                 week: .init(usedPct: 5, resetAt: now.addingTimeInterval(2 * 86_400).ISO8601Format()),
                                 contributors: [], skills: [], subagents: [])
        let pace = lanePace(snap, now: now)
        XCTAssertEqual(pace.status, "ROOM TO BURN")
        XCTAssertEqual(LaneLines.make(pace, todayNote: nil).status, "Plenty of room")
    }

    func testNoWidowKeepsTheLastWordsTogether() {
        XCTAssertEqual(noWidow("Installs a background refresh for the tools found. About 10 seconds."),
                       "Installs a background refresh for the tools found. About\u{00A0}10\u{00A0}seconds.")
        XCTAssertEqual(noWidow("Short line here"), "Short line here")
    }
}

/// VoiceOver hears each lane as one sentence.
final class LaneSpeechTests: XCTestCase {
    /// Wednesday 2026-09-30 at noon, local time.
    private let now: Date = {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 9; parts.day = 30; parts.hour = 12
        return Calendar.current.date(from: parts)!
    }()

    func testSpokenResetReadsInFull() {
        let iso = { (offset: TimeInterval) in self.now.addingTimeInterval(offset).ISO8601Format() }
        XCTAssertEqual(laneResetSpoken(nil, iso(90 * 60), now: now), "in 1 hour 30 minutes")
        XCTAssertEqual(laneResetSpoken(nil, iso(5 * 3600), now: now), "today at 5 PM")
        XCTAssertEqual(laneResetSpoken(nil, iso(24 * 3600 + 30 * 60), now: now), "tomorrow at 12:30 PM")
        XCTAssertEqual(laneResetSpoken(nil, iso(6 * 24 * 3600 + 6 * 3600 + 20 * 60), now: now), "Tuesday, October 6 at 6:20 PM")
    }

    func testLaneSentenceNamesPercentWindowResetAndPace() {
        let reset = now.addingTimeInterval(4 * 24 * 3600)
        let snap = UsageSnapshot(provider: "claude", capturedAt: now.ISO8601Format(),
                                 week: .init(usedPct: 89, resetAt: reset.ISO8601Format()),
                                 contributors: [], skills: [], subagents: [])
        let pace = lanePace(snap, now: now)
        let label = LaneSpeech.lane(name: "Claude", pace: pace,
                                    resetSpoken: laneResetSpoken(nil, reset.ISO8601Format(), now: now),
                                    freshness: LaneFreshness(state: .live, age: 0))
        XCTAssertEqual(label, "Claude, 89 percent of weekly limit used, resets Sunday, October 4 at 12 PM, running hot")
    }

    func testOldReadingIsSpoken() {
        let pace = LanePace(used: 45, elapsed: nil, windowTag: "5h", status: "PACE UNKNOWN", statusColor: .clear,
                            barColor: .clear, valueColor: .clear, sub: nil)
        let label = LaneSpeech.lane(name: "Claude", pace: pace, resetSpoken: nil,
                                    freshness: LaneFreshness(state: .old, age: 3 * 3600))
        XCTAssertEqual(label, "Claude, last reading 45 percent of 5-hour limit used, reading is 3 hours old")
    }
}
