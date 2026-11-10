import XCTest
@testable import CodexUsageHUD

final class ManualRefreshTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_781_600)

    private func snapshot(used: Int?, age: TimeInterval = 0, checked: String? = nil) throws -> UsageSnapshot {
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-age))
        let value = used.map(String.init) ?? "null"
        let json = """
        {"provider":"grok","capturedAt":"\(stamp)","updatedAt":"\(checked ?? stamp)",
        "sourceKind":"native_ui_observation","week":{"label":"week","usedPct":\(value)}}
        """
        return try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
    }

    func testUnchangedReadingsAreNotCalledUpdated() throws {
        let old = try snapshot(used: 30)
        let reread = try snapshot(used: 30, checked: "2030-01-01T00:00:00Z")
        let result = ManualRefreshFeedback.finished(.completed, before: [old], after: [reread], providers: ["grok"], now: now)
        XCTAssertEqual(result.title, "Checked · no new readings")
        XCTAssertEqual(result.checkedAt, now)
    }

    func testChangedUsableReadingHasVisibleSuccess() throws {
        let result = ManualRefreshFeedback.finished(.completed, before: [try snapshot(used: 25)], after: [try snapshot(used: 30)], providers: ["grok"], now: now)
        XCTAssertEqual(result.title, "Updated")
        XCTAssertFalse(result.needsAttention)
    }

    func testRealZeroIsUsableNotMissing() throws {
        let result = ManualRefreshFeedback.finished(.completed, before: [], after: [try snapshot(used: 0)], providers: ["grok"], now: now)
        XCTAssertEqual(result.title, "Updated")
    }

    /// A lane whose snapshot declares an observation source kind is read by
    /// hand: an empty or week-old reading must never turn the footer orange
    /// or claim "some readings unavailable" — that warning is for the
    /// always-on lanes this refresh can actually check.
    func testManualLaneMissingOrOldReadingsDoNotTriggerPartialStatus() throws {
        for snapshots in [[try snapshot(used: nil)], [try snapshot(used: 30, age: 604800)]] {
            let result = ManualRefreshFeedback.finished(.completed, before: [], after: snapshots, providers: ["grok"], now: now)
            XCTAssertNotEqual(result.title, "Checked · some readings unavailable")
            XCTAssertFalse(result.needsAttention)
            XCTAssertFalse(result.detail.contains("Grok"))
        }
    }

    func testHiddenSourcesDoNotCreateFalsePartialStatus() throws {
        let result = ManualRefreshFeedback.finished(.completed, before: [], after: [try snapshot(used: 30)], providers: ["grok"], now: now)
        XCTAssertFalse(result.needsAttention)
    }

    func testAllFailureStatesAreVisibleAndNeverPretendToBeCompleted() {
        for outcome in [ManualRefreshOutcome.unavailable, .failed(7), .alreadyRunning, .timedOut] {
            let result = ManualRefreshFeedback.finished(outcome, before: [], after: [], providers: [])
            XCTAssertNil(result.checkedAt)
            XCTAssertFalse(result.title.isEmpty)
            XCTAssertNotEqual(result.title, "Updated")
        }
    }

    private func script(_ contents: String, in directory: URL) throws -> URL {
        let path = directory.appendingPathComponent("refresh.sh")
        try ("#!/bin/bash\n" + contents + "\n").write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path
    }

    func testRunnerReportsActualExitStatus() throws {
        let directory = TestTemporaryDirectory.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (code, expected) in [(0, ManualRefreshOutcome.completed), (75, .alreadyRunning), (9, .failed(9))] {
            let path = try script("exit \(code)", in: directory)
            XCTAssertEqual(ManualRefreshService.run(script: path, environment: [:], timeout: 2), expected)
        }
    }

    func testMissingScriptHasActionableOutcome() {
        XCTAssertEqual(ManualRefreshService.run(script: URL(fileURLWithPath: "/does-not-exist/refresh.sh"), environment: [:], timeout: 1), .unavailable)
    }

    func testTimeoutDoesNotKillBackgroundWork() throws {
        let directory = TestTemporaryDirectory.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("completed")
        let path = try script("/bin/sleep 0.2\n/usr/bin/touch '\(marker.path)'", in: directory)
        XCTAssertEqual(ManualRefreshService.run(script: path, environment: [:], timeout: 0.02), .timedOut)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    @MainActor
    func testImmediateFeedbackDuplicateGuardAndTerminalFeedback() async throws {
        let state = UsageState()
        let started = LockedCount()
        let gate = DispatchSemaphore(value: 0)
        let prepare: @Sendable () -> PreparedUsageRefresh = {
            PreparedUsageRefresh(loadResult: UsageLoadResult(snapshots: [], errors: []), budgets: [:], overrideUntil: nil)
        }
        state.forceBudgetRefresh(run: {
            started.increment()
            _ = gate.wait(timeout: .now() + 2)
            return .completed
        }, prepare: prepare)
        XCTAssertTrue(state.isManualRefreshing)
        XCTAssertEqual(state.manualRefreshFeedback?.title, "Refreshing…")
        state.forceBudgetRefresh(run: { started.increment(); return .failed(9) }, prepare: prepare)
        gate.signal()
        for _ in 0..<200 where state.isManualRefreshing {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(state.isManualRefreshing)
        XCTAssertEqual(started.value, 1)
        XCTAssertNotEqual(state.manualRefreshFeedback?.title, "Refreshing…")
        XCTAssertNotNil(state.manualRefreshFeedback?.checkedAt)
    }
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
}
