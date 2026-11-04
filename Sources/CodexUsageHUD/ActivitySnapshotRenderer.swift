import AppKit
import SwiftUI

/// `CODEX_USAGE_HUD_ACTIVITY_SNAPSHOT=<png>`: renders the Activity window's
/// content offscreen (after one blocking read of the session logs) and
/// exits. Nothing is shown on screen.
@MainActor
enum ActivitySnapshotRenderer {
    static func render(to path: String) {
        NSApplication.shared.setActivationPolicy(.accessory)
        SnapshotMode.enabled = true
        let state = ActivityState()
        state.refreshNow()
        let size = ActivityWindowController.defaultContentSize
        let host = NSHostingView(rootView: ActivityView(state: state))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        // Offscreen: far outside every display, never in front of the user.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.03)) }
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do { try data.write(to: URL(fileURLWithPath: path)) }
        catch { FileHandle.standardError.write(Data("Activity snapshot failed: \(error)\n".utf8)); exit(1) }
        FileHandle.standardError.write(Data("activity snapshot written: \(path)\n".utf8))
        exit(0)
    }
}
