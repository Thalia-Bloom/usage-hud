import AppKit
import SwiftUI

/// The first launch of an LSUIElement app shows nothing, so a new user may
/// never find it. On the very first launch the panel opens by itself under
/// the menu-bar item, with a one-line callout pointing at the item.
enum FirstRun {
    static let presentedKey = "usageHUD.firstRun.presented"
    static let calloutText = "Usage HUD lives here in your menu bar."
    static let notchCalloutText = "Usage HUD is in your menu bar, but the notch is hiding it."

    /// True when the menu-bar item sits under the camera housing of a
    /// notched display. The window server still reports such an item as
    /// visible, so this goes by geometry: the notch is the gap between the
    /// screen's two auxiliary top areas.
    static func isHiddenByNotch(buttonRect: NSRect, topLeftArea: NSRect?, topRightArea: NSRect?) -> Bool {
        guard let left = topLeftArea, let right = topRightArea,
              !left.isEmpty, !right.isEmpty, right.minX > left.maxX
        else { return false }
        return buttonRect.midX > left.maxX && buttonRect.midX < right.minX
    }

    /// True exactly once per Mac user. Records the answer as it goes, so a
    /// crash or quit during the first run never brings it back. A copy that
    /// was already set up before this flag existed counts as seen. The
    /// offscreen snapshot path never presents and never records.
    static func shouldPresent(defaults: UserDefaults, snapshotMode: Bool, existingInstall: Bool) -> Bool {
        guard !snapshotMode else { return false }
        guard !defaults.bool(forKey: presentedKey) else { return false }
        defaults.set(true, forKey: presentedKey)
        defaults.removeObject(forKey: pendingKey)
        return !existingInstall
    }

    /// Set while a fresh install has not shown its first run yet. A copy
    /// that moves itself to Applications and relaunches has already written
    /// its preferences, so without this the relaunched copy would look like
    /// an upgrade and skip the first run.
    static let pendingKey = "usageHUD.firstRun.pending"

    /// Call once at launch, before `ProviderPreferences.ensureInitialized`.
    /// Returns whether this Mac counts as an existing install.
    static func noteLaunch(defaults: UserDefaults = .standard, setUpDone: () -> Bool = { BackgroundRefreshService.isInstalled() }) -> Bool {
        if defaults.bool(forKey: pendingKey) { return false }
        let existing = isExistingInstall(setUpDone: setUpDone)
        if !existing && !defaults.bool(forKey: presentedKey) {
            defaults.set(true, forKey: pendingKey)
        }
        return existing
    }

    /// An upgrade is a Mac where Set up already ran (its login item and
    /// helpers are in place). Preferences alone don't count: 1.2.0 wrote
    /// them on first launch even when it ran from Downloads and never set
    /// up, and those people still need the first run.
    static func isExistingInstall(setUpDone: () -> Bool = { BackgroundRefreshService.isInstalled() }) -> Bool {
        setUpDone()
    }
}

/// Borderless window for the callout. The panel's click-outside check
/// recognizes this class so tapping the callout does not close the panel.
final class FirstRunCalloutWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A one-line bubble under the menu-bar item with an arrow pointing at it.
/// Dismisses on click, on any click elsewhere, or after a few seconds.
@MainActor
final class FirstRunCallout {
    static let arrowHeight: CGFloat = 7

    /// Vertical room the panel leaves under the menu-bar item for the callout.
    static func reservedHeight(text: String = FirstRun.calloutText) -> CGFloat {
        NSHostingView(rootView: FirstRunCalloutView(text: text, arrowX: 0)).fittingSize.height + 6
    }

    private var window: FirstRunCalloutWindow?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var timer: Timer?
    private var onDismiss: (() -> Void)?

    func show(below anchor: NSRect, text: String = FirstRun.calloutText, duration: TimeInterval = 6, onDismiss: @escaping () -> Void) {
        dismiss(animated: false)
        self.onDismiss = onDismiss

        let probe = NSHostingView(rootView: FirstRunCalloutView(text: text, arrowX: 0))
        let size = probe.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 8
        var x = anchor.midX - size.width / 2
        x = max(visible.minX + margin, min(x, visible.maxX - size.width - margin))
        let y = anchor.minY - size.height - 2
        let arrowX = min(max(anchor.midX - x, 16), size.width - 16)

        let host = NSHostingView(rootView: FirstRunCalloutView(text: text, arrowX: arrowX) { [weak self] in
            self?.dismiss(animated: true)
        })
        host.frame = NSRect(origin: .zero, size: size)

        let window = FirstRunCalloutWindow(
            contentRect: NSRect(x: x, y: y, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.setAccessibilityLabel(text)
        self.window = window

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let target = window.frame
        window.alphaValue = 0
        if !reduceMotion { window.setFrame(target.offsetBy(dx: 0, dy: 6), display: false) }
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduceMotion ? 0.15 : 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            if !reduceMotion { window.animator().setFrame(target, display: true) }
        }
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.dismiss(animated: true) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in self?.dismiss(animated: true) }
            return event
        }
        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss(animated: true) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func dismiss(animated: Bool) {
        timer?.invalidate()
        timer = nil
        for monitor in [globalMonitor, localMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        globalMonitor = nil
        localMonitor = nil
        guard let window else { return }
        self.window = nil
        let callback = onDismiss
        onDismiss = nil
        callback?()
        guard animated else {
            window.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in window.orderOut(nil) }
        })
    }
}

private struct FirstRunCalloutView: View {
    let text: String
    let arrowX: CGFloat
    var onTap: () -> Void = {}

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.up")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .padding(.top, FirstRunCallout.arrowHeight)
        .background(
            CalloutShape(arrowX: arrowX, arrowHeight: FirstRunCallout.arrowHeight, radius: 10)
                .fill(Color(red: 0.13, green: 0.14, blue: 0.18).opacity(0.97))
                .overlay(
                    CalloutShape(arrowX: arrowX, arrowHeight: FirstRunCallout.arrowHeight, radius: 10)
                        .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// Rounded rectangle with a small arrow on its top edge at `arrowX`.
private struct CalloutShape: Shape {
    let arrowX: CGFloat
    let arrowHeight: CGFloat
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY + arrowHeight, width: rect.width, height: rect.height - arrowHeight)
        let half: CGFloat = 7
        let tipX = min(max(arrowX, body.minX + radius + half), body.maxX - radius - half)
        var path = Path()
        path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
        path.addLine(to: CGPoint(x: tipX - half, y: body.minY))
        path.addQuadCurve(to: CGPoint(x: tipX, y: rect.minY), control: CGPoint(x: tipX - 2, y: body.minY))
        path.addQuadCurve(to: CGPoint(x: tipX + half, y: body.minY), control: CGPoint(x: tipX + 2, y: body.minY))
        path.addLine(to: CGPoint(x: body.maxX - radius, y: body.minY))
        path.addArc(center: CGPoint(x: body.maxX - radius, y: body.minY + radius), radius: radius, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - radius))
        path.addArc(center: CGPoint(x: body.maxX - radius, y: body.maxY - radius), radius: radius, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: body.minX + radius, y: body.maxY))
        path.addArc(center: CGPoint(x: body.minX + radius, y: body.maxY - radius), radius: radius, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: body.minX, y: body.minY + radius))
        path.addArc(center: CGPoint(x: body.minX + radius, y: body.minY + radius), radius: radius, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}
