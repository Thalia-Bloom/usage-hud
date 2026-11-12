import XCTest
@testable import CodexUsageHUD

final class ICloudUsageSnapshotTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCompactEncodingOnlyContainsAllowedFields() throws {
        let snapshot = ICloudUsageSnapshot(writtenAt: 1_800_000_000, mac: "Test Mac", providers: [
            .init(id: "codex", name: "Codex", windows: [.make(label: "Week", usedPct: 42,
                resetAt: now.addingTimeInterval(3600), readAt: now, now: now)])])
        let data = try snapshot.encoded()
        XCTAssertLessThan(data.count, 1024)
        XCTAssertEqual(try JSONDecoder().decode(ICloudUsageSnapshot.self, from: data), snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["t", "m", "p"])
        let provider = try XCTUnwrap((object["p"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(provider.keys), ["i", "n", "w"])
        let window = try XCTUnwrap((provider["w"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(window.keys), ["l", "u", "r", "a", "s"])
    }

    func testFiveProvidersWithTwoWindowsFit() throws {
        let providers = ["codex", "claude", "gemini", "grok", "local"].map { id in
            ICloudUsageSnapshot.Provider(id: id, name: id.capitalized, windows: ["5 hours", "Week"].map {
                .make(label: $0, usedPct: 99.1, resetAt: now.addingTimeInterval(60000), readAt: now, now: now)
            })
        }
        XCTAssertLessThan(try ICloudUsageSnapshot(writtenAt: 1_800_000_000, mac: "My Mac", providers: providers).encoded().count, 1024)
    }

    func testOversizeNeverPublishesPartialData() {
        let huge = ICloudUsageSnapshot(writtenAt: 1, mac: String(repeating: "🐱", count: 300), providers: [])
        XCTAssertThrowsError(try huge.encoded())
    }

    func testLiveBoundaryAndMissingReadings() {
        typealias W = ICloudUsageSnapshot.Window
        func window(_ age: Double, _ pct: Double? = 10) -> W {
            .make(label: "Week", usedPct: pct, resetAt: nil, readAt: now.addingTimeInterval(-age), now: now)
        }
        XCTAssertEqual(window(600).state, .live)
        XCTAssertEqual(window(601).state, .old)
        XCTAssertEqual(window(3601).state, .old)
        XCTAssertEqual(window(10801).state, .old)
        XCTAssertEqual(window(0, nil).state, .missing)
        XCTAssertEqual(window(0, .nan).state, .missing)
        XCTAssertEqual(window(-60).state, .old)
        XCTAssertEqual(W.make(label: "Week", usedPct: 20, resetAt: now, readAt: now, now: now).state, .old)
        XCTAssertEqual(W.make(label: "Week", usedPct: 20, resetAt: nil, readAt: nil, now: now).state, .old)
    }

    func testPreferenceDefaultsOnlyAfterSetupAndOffRemovesKey() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "icloud-snapshot-test-\(UUID())"))
        let store = FakeCloudStore()
        let publisher = ICloudSnapshotPublisher(defaults: defaults, store: store)
        publisher.initializeAfterSetup(false)
        XCTAssertFalse(publisher.enabled)
        publisher.initializeAfterSetup(true)
        XCTAssertTrue(publisher.enabled)
        let snapshot = ICloudUsageSnapshot(writtenAt: 1, mac: "Mac", providers: [])
        publisher.publish(snapshot)
        XCTAssertNotNil(store.data)
        publisher.setEnabled(false)
        XCTAssertNil(store.data)
        publisher.initializeAfterSetup(true)
        publisher.publish(snapshot)
        XCTAssertFalse(publisher.enabled)
        XCTAssertNil(store.data)
        defaults.removeObject(forKey: ICloudSnapshotPublisher.preferenceKey)
    }
}

private final class FakeCloudStore: ICloudSnapshotStore {
    var data: Data?
    func put(_ data: Data, forKey key: String) { self.data = data }
    func remove(_ key: String) { data = nil }
    func synchronize() -> Bool { true }
}
