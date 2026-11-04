import Foundation
import XCTest
@testable import CodexUsageHUD

@MainActor
final class BadgePayloadTests: XCTestCase {
    private let allowedKeys: Set<String> = [
        "provider", "window", "label", "style", "color", "showUsed",
        "usedPct", "capturedAt", "resetAt", "confidence"
    ]

    // Replace only the in-memory configuration and restore it even on failure.
    // Calling payload never saves settings or contacts the badge service.
    private func withBadge(_ body: (ReadmeBadge) throws -> Void) rethrows {
        let badge = ReadmeBadge.shared
        let original = badge.config
        defer { badge.config = original }
        var config = ReadmeBadge.Configuration()
        config.token = "badge-payload-test-token"
        config.provider = "claude"
        config.window = "week"
        config.label = "My usage"
        config.style = "flat-square"
        config.color = "brand"
        config.showUsed = false
        badge.config = config
        try body(badge)
    }

    private func reading(now: Date) -> UsageSnapshot {
        UsageSnapshot(
            provider: "claude", confidence: "official",
            capturedAt: now.ISO8601Format(),
            week: .init(usedPct: 42, resetAt: now.addingTimeInterval(3600).ISO8601Format(),
                        capturedAt: now.addingTimeInterval(-60).ISO8601Format()),
            contributors: [], skills: [], subagents: []
        )
    }

    private func json(_ payload: ReadmeBadge.Payload) throws -> [String: Any] {
        let data = try JSONEncoder().encode(payload)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testFreshPayloadHasExactlyThePublicAllowlistAndNoCredentialOrBadgeID() throws {
        try withBadge { badge in
            let snapshot = reading(now: Date())
            let payload = badge.payload([snapshot])
            let object = try json(payload)
            XCTAssertEqual(Set(object.keys), allowedKeys)
            XCTAssertEqual(object["provider"] as? String, "claude")
            XCTAssertEqual(object["window"] as? String, "week")
            XCTAssertEqual(object["label"] as? String, "My usage")
            XCTAssertEqual(object["style"] as? String, "flat-square")
            XCTAssertEqual(object["color"] as? String, "brand")
            XCTAssertEqual(object["showUsed"] as? Bool, false)
            XCTAssertEqual(object["usedPct"] as? Double, 42)
            XCTAssertEqual(object["capturedAt"] as? String, snapshot.week?.capturedAt)
            XCTAssertEqual(object["resetAt"] as? String, snapshot.week?.resetAt)
            XCTAssertEqual(object["confidence"] as? String, "official")
            let encoded = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
            XCTAssertFalse(encoded.contains(badge.config.token))
            XCTAssertFalse(encoded.contains(badge.id))
            XCTAssertNil(object["token"])
            XCTAssertNil(object["id"])
            XCTAssertNil(object["badgeId"])
        }
    }

    func testTwoHourOldWindowNeverPublishesANumberEvenWithFreshSnapshot() throws {
        try withBadge { badge in
            let now = Date()
            var snapshot = reading(now: now)
            snapshot.week?.capturedAt = now.addingTimeInterval(-2 * 3600).ISO8601Format()
            let object = try json(badge.payload([snapshot]))
            XCTAssertEqual(Set(object.keys), allowedKeys)
            XCTAssertTrue(object["usedPct"] is NSNull)
        }
    }

    func testEachHealthWarningSuppressesAnOtherwiseFreshNumber() throws {
        try withBadge { badge in
            let fresh = reading(now: Date())
            var laneWarning = fresh
            laneWarning.health = .init(verdict: "degraded")
            var providerWarning = fresh
            providerWarning.providerHealth = .init(status: "unavailable")
            var officialWarning = fresh
            officialWarning.officialUsageStatus = .init(status: "unavailable")
            for (name, snapshot) in [("lane", laneWarning), ("provider", providerWarning),
                                     ("official usage", officialWarning)] {
                let object = try json(badge.payload([snapshot]))
                XCTAssertTrue(object["usedPct"] is NSNull, "\(name) warning must suppress usage")
            }
        }
    }

    func testPastResetNeverPublishesAnOtherwiseFreshNumber() throws {
        try withBadge { badge in
            let now = Date()
            var snapshot = reading(now: now)
            snapshot.week?.resetAt = now.addingTimeInterval(-60).ISO8601Format()
            XCTAssertTrue(try json(badge.payload([snapshot]))["usedPct"] is NSNull)
        }
    }

    func testLabelIsCappedAt24CharactersAndUnknownConfidenceIsNormalized() throws {
        try withBadge { badge in
            // A multi-scalar character pins the user-visible character limit.
            badge.config.label = String(repeating: "👩🏽‍💻", count: 30)
            var snapshot = reading(now: Date())
            snapshot.confidence = "unrecognized-confidence"
            let object = try json(badge.payload([snapshot]))
            let label = try XCTUnwrap(object["label"] as? String)
            XCTAssertEqual(label, String(repeating: "👩🏽‍💻", count: 24))
            XCTAssertEqual(label.count, 24)
            XCTAssertEqual(object["confidence"] as? String, "unknown")
        }
    }

    func testUnavailableWindowKeepsExplicitNullsAndTheSameAllowlist() throws {
        try withBadge { badge in
            let object = try json(badge.payload([]))
            XCTAssertEqual(Set(object.keys), allowedKeys)
            XCTAssertTrue(object["usedPct"] is NSNull)
            XCTAssertTrue(object["resetAt"] is NSNull)
            XCTAssertEqual(object["confidence"] as? String, "unknown")
        }
    }
}
