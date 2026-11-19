import AppKit
import SwiftUI

@main
@MainActor
struct CodexUsageHUDApp {
    static func main() {
        // `status`, `room`, `mcp`, `prompt`: answer and exit before any GUI.
        if let code = AgentCLI.runIfRequested() {
            exit(code)
        }
        if let out = ProcessInfo.processInfo.environment["CODEX_USAGE_HUD_ACTIVITY_SNAPSHOT"], !out.isEmpty {
            ActivitySnapshotRenderer.render(to: out)
            return
        }
        // Design-verification path: render the real SwiftUI panel (with live data)
        // straight to a PNG and exit. Reusable for every redesign pass.
        if let out = ProcessInfo.processInfo.environment["CODEX_USAGE_HUD_SNAPSHOT"], !out.isEmpty {
            SnapshotRenderer.render(to: out)
            return
        }
        // Menu-bar glyph verification: render every mode on dark + light menu-bar
        // swatches to one PNG and exit. Reusable for glyph design passes.
        if let out = ProcessInfo.processInfo.environment["CODEX_USAGE_HUD_GLYPH_SNAPSHOT"], !out.isEmpty {
            GlyphSnapshot.render(to: out)
            return
        }
        // Proof path for the token readers: the spend and activity summaries
        // as JSON (numbers, model ids, project names), written only to the
        // given path, then exit.
        if let out = ProcessInfo.processInfo.environment["CODEX_USAGE_HUD_SPEND_PROBE"], !out.isEmpty {
            exit(SpendProbe.run(outputPath: out))
        }
        // Offscreen Settings renders for design checks.
        if let out = ProcessInfo.processInfo.environment["CODEX_USAGE_HUD_SETTINGS_SNAPSHOT"], !out.isEmpty {
            exit(SettingsWindowController.renderSnapshots(to: out))
        }
        if SingleInstanceGuard.activateExistingInstanceIfRunning() {
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
enum SnapshotRenderer {
    static func render(to path: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        SnapshotMode.enabled = true
        let height = ProcessInfo.processInfo.environment["CODEX_USAGE_HUD_SNAPSHOT_HEIGHT"].flatMap { Double($0) }.map { CGFloat($0) }
        SnapshotMode.height = height
        SnapshotMode.collapsed = ProcessInfo.processInfo.environment["CODEX_USAGE_HUD_SNAPSHOT_COLLAPSED"] == "1"

        ProviderPreferences.ensureInitialized()
        let state = UsageState()
        state.refreshNow()

        let host = NSHostingView(rootView: UsageView(state: state))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: height ?? 620)
        host.wantsLayer = true

        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = host
        // Far outside every display: the capture never shows on screen.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()

        // Let the async refresh land and SwiftUI commit layout.
        pump(seconds: 1.8)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        pump(seconds: 0.5)

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            FileHandle.standardError.write(Data("snapshot: no bitmap rep\n".utf8)); exit(1)
        }
        host.cacheDisplay(in: host.bounds, to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot: png encode failed\n".utf8)); exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write(Data("snapshot written: \(path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("snapshot write failed: \(error)\n".utf8)); exit(1)
        }
        exit(0)
    }

    private static func pump(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.03))
        }
    }
}

@MainActor
enum GlyphSnapshot {
    private static func lane(_ name: String, _ used: Double?, _ mode: String) -> GlyphLane {
        GlyphLane(name: name, usedPct: used, mode: mode, isConnected: used != nil)
    }

    // Representative fleet states the menu bar actually shows: calm week,
    // a low-percent ladder (0/10/20/30/39), mixed pressure, everything hot,
    // a lanes-missing morning, one lane, and the widest eight-lane fleet.
    private static let cases: [[GlyphLane]] = [
        [lane("Claude", 28, "green"), lane("Fable", 39, "green"), lane("Codex", 12, "green"), lane("Gemini", 4, "green"), lane("Grok", 55, "green")],
        [lane("Claude", 0, "green"), lane("Fable", 10, "green"), lane("Codex", 20, "green"), lane("Gemini", 30, "green"), lane("Grok", 39, "green")],
        [lane("Claude", 71, "yellow"), lane("Fable", 64, "yellow"), lane("Codex", 88, "orange"), lane("Gemini", 30, "green"), lane("Grok", nil, "unknown")],
        [lane("Claude", 97, "red"), lane("Fable", 92, "red"), lane("Codex", 100, "freeze"), lane("Gemini", 84, "orange"), lane("Grok", 76, "yellow")],
        [lane("Claude", 0, "green"), lane("Fable", nil, "unknown"), lane("Codex", nil, "unknown"), lane("Gemini", nil, "unknown"), lane("Grok", nil, "unknown")],
        [lane("Codex", 46, "green")],
        [lane("Claude", 22, "green"), lane("Fable", 35, "green"), lane("Codex", 61, "yellow"), lane("Gemini", 8, "green"),
         lane("Grok", 50, "green"),
         GlyphLane(name: "Local Models", usedPct: nil, mode: "local", isConnected: true)],
    ]

    /// Renders every case on a dark and a light menu-bar strip, next to the
    /// system's own Wi-Fi and battery symbols for weight comparison.
    /// `CODEX_USAGE_HUD_GLYPH_SCALE` sets pixels per point (1, 2 or 3).
    static func render(to path: String) {
        let scale = ProcessInfo.processInfo.environment["CODEX_USAGE_HUD_GLYPH_SCALE"].flatMap { Double($0) }.map { CGFloat($0) } ?? 3
        let rowH: CGFloat = 24, pad: CGFloat = 10, colW: CGFloat = 110, rowGap: CGFloat = 6
        let W = pad * 3 + colW * 2
        let H = pad * 2 + (rowH + rowGap) * CGFloat(cases.count) - rowGap

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { FileHandle.standardError.write(Data("glyph snapshot: no rep\n".utf8)); exit(1) }
        rep.size = NSSize(width: W, height: H)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: W, height: H).fill()

        let darkBar = NSColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 1)
        let lightBar = NSColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1)
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let references = ["wifi", "battery.75percent"].compactMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfig)
        }

        for (row, lanes) in cases.enumerated() {
            let img = UsageStatusIcon.image(lanes: lanes)
            let y = H - pad - rowH * CGFloat(row + 1) - rowGap * CGFloat(row)
            for (column, isDark) in [true, false].enumerated() {
                let colX = pad + (colW + pad) * CGFloat(column)
                (isDark ? darkBar : lightBar).setFill()
                NSRect(x: colX, y: y, width: colW, height: rowH).fill()
                let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
                appearance?.performAsCurrentDrawingAppearance {
                    var x = colX + 8
                    for image in [img] + references {
                        // Status items center their image on whole points.
                        let origin = NSPoint(x: x, y: y + ((rowH - image.size.height) / 2).rounded())
                        drawMenuBarImage(image, in: NSRect(origin: origin, size: image.size))
                        x += image.size.width.rounded(.up) + 12
                    }
                }
            }
        }

        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("glyph snapshot: png failed\n".utf8)); exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write(Data("glyph snapshot written: \(path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("glyph snapshot write failed: \(error)\n".utf8)); exit(1)
        }
        exit(0)
    }

    /// The menu bar tints template images with its foreground color; a plain
    /// draw would leave them black. Non-template images draw as they are.
    static func drawMenuBarImage(_ image: NSImage, in rect: NSRect) {
        guard image.isTemplate else {
            image.draw(in: rect)
            return
        }
        let tinted = NSImage(size: image.size, flipped: false) { bounds in
            image.draw(in: bounds)
            NSColor.labelColor.withAlphaComponent(1).set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect)
    }
}
