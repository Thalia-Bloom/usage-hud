import AppKit
import XCTest
@testable import CodexUsageHUD

final class QuietFixesTests: XCTestCase {
    func testAPIValueSplitsDollarsFromTokens() {
        let split = APIValueDisplay.split("$93 today · 794.1K today · $5,922 week · 55.2M week")
        XCTAssertEqual(split.dollars, ["$93 today", "$5,922 week"])
        XCTAssertEqual(split.tokens, ["794.1K today", "55.2M week"])
    }

    func testCodexCreditsDecodeFromWriterJSON() throws {
        let json = #"{"provider":"codex","credits":{"hasCredits":true,"unlimited":false,"balance":62500}}"#
        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.credits?.balance, 62500)
        XCTAssertEqual(CreditsDisplay.laneNote(snapshot.credits), "62.5K credits")
        XCTAssertTrue(CreditsDisplay.detail(snapshot.credits)?.hasPrefix("62,500 left") == true)
    }

    func testEmptyOrMissingCreditsStayOffThePanel() throws {
        XCTAssertNil(CreditsDisplay.laneNote(nil))
        XCTAssertNil(CreditsDisplay.laneNote(.init(hasCredits: false, unlimited: false, balance: 0)))
        XCTAssertEqual(CreditsDisplay.laneNote(.init(hasCredits: true, unlimited: true, balance: nil)), "unlimited credits")
        // A malformed credits block must not break the rest of the snapshot.
        let json = #"{"provider":"codex","credits":"lots","week":{"usedPct":40}}"#
        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.credits)
        XCTAssertEqual(snapshot.week?.usedPct, 40)
    }

    func testBudgetStateSkipsUnchangedRewrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        let now = Date()
        func payload(_ weekly: Double, stamp: Date) -> [String: Any] {
            ["mode": "green", "weeklyUsedPct": weekly, "driverAlerts": [["label": "x", "percent": 10]],
             "updatedAt": ISO8601DateFormatter().string(from: stamp)]
        }
        XCTAssertTrue(BudgetEvaluator.shouldRewrite(payload(3, stamp: now), at: url, now: now), "no file yet")
        try JSONSerialization.data(withJSONObject: payload(3, stamp: now)).write(to: url)
        XCTAssertFalse(BudgetEvaluator.shouldRewrite(payload(3, stamp: now.addingTimeInterval(5)), at: url, now: now.addingTimeInterval(5)))
        XCTAssertTrue(BudgetEvaluator.shouldRewrite(payload(4, stamp: now.addingTimeInterval(5)), at: url, now: now.addingTimeInterval(5)), "value changed")
        XCTAssertTrue(BudgetEvaluator.shouldRewrite(payload(3, stamp: now.addingTimeInterval(61)), at: url, now: now.addingTimeInterval(61)), "stamp over a minute old")
    }

    /// A colored (non-template) menu bar icon must resolve its calm bars in
    /// the bar's own appearance: light on a dark bar, dark on a light bar.
    @MainActor
    func testMenuBarIconFollowsBarAppearance() throws {
        let image = UsageStatusIcon.image(lanes: [
            GlyphLane(name: "Claude", usedPct: 40, mode: "green", isConnected: true),
            GlyphLane(name: "Codex", usedPct: 90, mode: "orange", isConnected: true),
        ])
        XCTAssertFalse(image.isTemplate, "a lane that needs attention adds color, so no template")
        func calmBarBrightness(_ name: NSAppearance.Name) throws -> Double {
            let scale = 4
            let rep = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(image.size.width) * scale, pixelsHigh: Int(image.size.height) * scale,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            rep.size = image.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                image.draw(in: NSRect(origin: .zero, size: image.size))
            }
            NSGraphicsContext.restoreGraphicsState()
            // The first (calm) bar's column; the faint track is under 0.5
            // alpha, so only the fill counts.
            let barMinX = Int(UsageStatusIcon.sidePad) * scale
            let barMaxX = barMinX + Int(UsageStatusIcon.barWidth) * scale
            var total = 0.0, count = 0.0
            for y in 0..<rep.pixelsHigh {
                for x in barMinX..<barMaxX {
                    guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5 else { continue }
                    total += (c.redComponent + c.greenComponent + c.blueComponent) / 3
                    count += 1
                }
            }
            return count > 0 ? total / count : -1
        }
        let onDark = try calmBarBrightness(.darkAqua)
        let onLight = try calmBarBrightness(.aqua)
        XCTAssertGreaterThan(onDark, 0.6, "calm bars should be light on a dark bar")
        XCTAssertGreaterThanOrEqual(onLight, 0, "calm bar fill should be drawn")
        XCTAssertLessThan(onLight, 0.4, "calm bars should be dark on a light bar")
    }
}
