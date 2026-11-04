import XCTest
@testable import CodexUsageHUD

final class RefreshCacheTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("refresh-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testUnchangedFileIsNotRecomputed() throws {
        let url = try tempDir().appendingPathComponent("a.json")
        try Data("one".utf8).write(to: url)
        let cache = FileSignatureCache<String>()
        var computes = 0
        let read: (URL) -> String = { computes += 1; return (try? String(contentsOf: $0, encoding: .utf8)) ?? "" }

        XCTAssertEqual(cache.value(for: url, compute: read), "one")
        XCTAssertEqual(cache.value(for: url, compute: read), "one")
        XCTAssertEqual(cache.value(for: url, compute: read), "one")
        XCTAssertEqual(computes, 1)
        XCTAssertEqual(cache.loads, 1)
    }

    func testChangedSizeOrModificationDateRecomputes() throws {
        let url = try tempDir().appendingPathComponent("a.json")
        try Data("one".utf8).write(to: url)
        let cache = FileSignatureCache<String>()
        let read: (URL) -> String = { (try? String(contentsOf: $0, encoding: .utf8)) ?? "" }
        XCTAssertEqual(cache.value(for: url, compute: read), "one")

        try Data("three".utf8).write(to: url)
        XCTAssertEqual(cache.value(for: url, compute: read), "three")
        XCTAssertEqual(cache.loads, 2)

        // Same size, new mtime: still a change.
        try Data("trees".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 120)], ofItemAtPath: url.path
        )
        XCTAssertEqual(cache.value(for: url, compute: read), "trees")
        XCTAssertEqual(cache.loads, 3)
    }

    func testCodexTailParseIsReusedUntilSessionFileChanges() throws {
        let root = try tempDir()
        func event(_ pct: Double, _ ts: String) -> String {
            """
            {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","primary":{"used_percent":\(pct),"window_minutes":300,"resets_at":1893456000},"secondary":{"used_percent":10.0,"window_minutes":10080,"resets_at":1894060800},"plan_type":"pro"}}}
            """
        }
        let file = root.appendingPathComponent("s.jsonl")
        try (event(20, "2026-06-13T10:00:00Z") + "\n").write(to: file, atomically: true, encoding: .utf8)

        let start = CodexSessionReader.tailParseCount
        XCTAssertEqual(CodexSessionReader.loadSnapshot(fromSessionsRoot: root)?.currentSession?.usedPct, 20.0)
        XCTAssertEqual(CodexSessionReader.loadSnapshot(fromSessionsRoot: root)?.currentSession?.usedPct, 20.0)
        XCTAssertEqual(CodexSessionReader.tailParseCount - start, 1)

        let appended = event(20, "2026-06-13T10:00:00Z") + "\n" + event(55, "2026-06-13T10:05:00Z") + "\n"
        try appended.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(CodexSessionReader.loadSnapshot(fromSessionsRoot: root)?.currentSession?.usedPct, 55.0)
        XCTAssertEqual(CodexSessionReader.tailParseCount - start, 2)
    }
}
