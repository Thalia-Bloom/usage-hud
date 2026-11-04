import AppKit
import SwiftUI
import XCTest
@testable import CodexUsageHUD

@MainActor
final class AgentOnboardingViewTests: XCTestCase {
    /// Lays the view out at Settings width. Set AGENT_ONBOARDING_PNG=/path.png
    /// to also write a picture of it for design review.
    func testLaysOutAtSettingsWidth() throws {
        let prompt = AgentPrompt.text(executablePath: "/Applications/Usage HUD.app/Contents/MacOS/CodexUsageHUD", home: "/Users/you")
        let host = NSHostingView(rootView: AgentOnboardingView(prompt: prompt).padding(16).frame(width: 460)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 150)
        XCTAssertLessThan(host.fittingSize.height, 420, "the prompt scrolls; the view stays compact")

        if let out = ProcessInfo.processInfo.environment["AGENT_ONBOARDING_PNG"], !out.isEmpty {
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.displayIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: out))
        }
    }
}
