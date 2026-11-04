import Foundation
import XCTest
@testable import CodexUsageHUD

final class SupportReportLabelTests: XCTestCase {
    func testEveryDoctorCheckNameHasAPlainLabel() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let doctor = try String(contentsOf: root.appendingPathComponent("bin/codex-usage-doctor"), encoding: .utf8)
        // add's first argument is a status expression; the other helpers take
        // the check name first. Include multiline calls, but not dynamic names.
        let pattern = #"\b(?:add\s*\([^,\n]*,\s*|(?:checkPath|checkWriterErrorLog|checkNodeCommand|checkLaunchAgent)\s*\(\s*)['"]([^'"]+)['"]"#
        let regex = try NSRegularExpression(pattern: pattern)
        let names = Set(regex.matches(in: doctor, range: NSRange(doctor.startIndex..., in: doctor)).compactMap { match in
            Range(match.range(at: 1), in: doctor).map { String(doctor[$0]) }
        })
        XCTAssertTrue(names.isSuperset(of: ["codex home", "session logs", "claude budget guard hook"]))
        XCTAssertTrue(names.contains("com.codexusagehud.app"))
        for name in names.sorted() {
            XCTAssertNotEqual(SupportReport.label(name), "Other health check", name)
        }
    }

    func testSessionLogsAndGuardHookNextSteps() {
        XCTAssertEqual(SupportReport.nextSteps("FAIL  session logs: no logs"),
                       SupportReport.nextSteps("FAIL  codex sessions: missing"))
        let steps = SupportReport.nextSteps("WARN  claude budget guard hook: missing")
        XCTAssertEqual(steps.count, 1)
        XCTAssertTrue(steps[0].contains("optional"))
        XCTAssertTrue(steps[0].contains("Help and support"))
        XCTAssertFalse(steps[0].contains("check that you are signed in"))
    }
}
