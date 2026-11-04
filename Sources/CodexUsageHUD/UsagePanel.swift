import AppKit
import SwiftUI

final class UsagePanel: NSPanel {
    /// Called for Esc / ⌘. when the panel is key (the responder chain's
    /// `cancelOperation:`).
    var onCancel: (() -> Void)?

    init(content: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 620),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.hidesOnDeactivate = false
        self.becomesKeyOnlyIfNeeded = false
        self.isMovable = false
        self.isMovableByWindowBackground = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isReleasedWhenClosed = false
        // The panel is designed for dark glass. Without a fixed appearance the
        // material follows Light Mode and a pale desktop washes it to grey
        // behind white text, and system controls render light.
        self.appearance = NSAppearance(named: .darkAqua)
        self.contentView = content
    }

    /// A non-activating panel may become key without activating the app, so
    /// Esc reaches it while the app the user was in stays frontmost.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Timings for the panel's open/close. With Reduce Motion on, the slide is
/// dropped and only a short cross-fade remains.
enum PanelMotion {
    static func slideOffset(reduceMotion: Bool) -> CGFloat { reduceMotion ? 0 : 14 }
    static func showDuration(reduceMotion: Bool) -> TimeInterval { reduceMotion ? 0.12 : 0.20 }
    static func hideDuration(reduceMotion: Bool) -> TimeInterval { reduceMotion ? 0.10 : 0.14 }
    static func resizeDuration(reduceMotion: Bool) -> TimeInterval { reduceMotion ? 0 : 0.18 }
}

enum PanelKeys {
    static let escapeKeyCode: UInt16 = 53

    /// Esc, ⌘W and ⌘. close the panel.
    static func closes(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) -> Bool {
        let flags = modifiers.intersection([.command, .option, .control, .shift])
        if keyCode == escapeKeyCode && flags.isEmpty { return true }
        if flags == .command, let characters, ["w", "."].contains(characters.lowercased()) { return true }
        return false
    }
}

@MainActor
final class UsagePanelController {
    private let state: UsageState
    private let panel: UsagePanel
    private(set) var isShown = false
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var statusItemScreenRect: NSRect = .zero
    /// Extra room between the menu-bar item and the panel. Only the first-run
    /// callout uses it; it closes back to zero when the callout goes away.
    private var topGap: CGFloat = 0

    /// Tells the status item to keep its highlight while the panel is open.
    var onVisibilityChange: ((Bool) -> Void)?

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(state: UsageState) {
        self.state = state
        let host = NSHostingView(rootView: UsageView(state: state))
        host.frame = NSRect(x: 0, y: 0, width: PanelMetrics.width, height: PanelMetrics.preferredHeight)
        host.autoresizingMask = [.width, .height]
        self.panel = UsagePanel(content: host)
        panel.onCancel = { [weak self] in self?.hide() }

        // The details fold changes the content height; resize the window from
        // its top edge so the panel stays glued under the status item.
        NotificationCenter.default.addObserver(
            forName: PanelMetrics.heightDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyPreferredHeight() }
        }
    }

    private func applyPreferredHeight() {
        guard isShown else { return }
        let height = PanelMetrics.preferredHeight
        guard abs(panel.frame.height - height) > 0.5 else { return }
        let target = NSRect(
            x: panel.frame.origin.x,
            y: panel.frame.maxY - height,
            width: panel.frame.width,
            height: height
        )
        let duration = PanelMotion.resizeDuration(reduceMotion: reduceMotion)
        guard duration > 0 else {
            panel.setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    func toggle(anchor statusItem: NSStatusItem) {
        isShown ? hide() : show(anchor: statusItem)
    }

    /// Opens the panel under the menu-bar item. `topGap` pushes it down to
    /// leave room for the first-run callout.
    func show(anchor statusItem: NSStatusItem, topGap: CGFloat = 0) {
        guard !isShown,
              let button = statusItem.button,
              let buttonWindow = button.window
        else { return }

        state.notePanelOpened()
        state.refresh()

        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        statusItemScreenRect = buttonRect.insetBy(dx: -8, dy: -8)
        let size = NSSize(width: PanelMetrics.width, height: PanelMetrics.preferredHeight)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(buttonRect.origin) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 8
        self.topGap = max(0, topGap)

        var x = buttonRect.midX - (size.width / 2)
        x = max(visible.minX + margin, min(x, visible.maxX - size.width - margin))
        var y = buttonRect.minY - size.height - 4 - self.topGap
        y = max(visible.minY + margin, y)
        let reduce = reduceMotion
        let target = NSRect(x: x, y: y, width: size.width, height: size.height)
        let start = target.offsetBy(dx: 0, dy: PanelMotion.slideOffset(reduceMotion: reduce))

        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = PanelMotion.showDuration(reduceMotion: reduce)
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            if start != target { panel.animator().setFrame(target, display: true) }
        }
        isShown = true
        installMonitors()
        onVisibilityChange?(true)
    }

    /// Slides the panel up into its normal place once the first-run callout
    /// has gone.
    func closeTopGap() {
        guard topGap > 0 else { return }
        let gap = topGap
        topGap = 0
        guard isShown else { return }
        let target = panel.frame.offsetBy(dx: 0, dy: gap)
        if reduceMotion {
            panel.setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        topGap = 0
        removeMonitors()
        onVisibilityChange?(false)
        guard panel.isVisible else { return }
        let reduce = reduceMotion
        let end = panel.frame.offsetBy(dx: 0, dy: PanelMotion.slideOffset(reduceMotion: reduce))
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = PanelMotion.hideDuration(reduceMotion: reduce)
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            if end != panel.frame { panel.animator().setFrame(end, display: true) }
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                // A quick reopen during the fade must not be ordered out.
                guard let self, !self.isShown else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    private func installMonitors() {
        removeMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handlePotentialDismiss(event: event)
            return event
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handlePotentialDismiss(event: event)
        }

        // Key events only reach the app while the panel is key, so this
        // never sees keystrokes meant for other apps.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isShown, event.window === self.panel,
                  PanelKeys.closes(keyCode: event.keyCode, modifiers: event.modifierFlags, characters: event.charactersIgnoringModifiers)
            else { return event }
            self.hide()
            return nil
        }
    }

    private func removeMonitors() {
        for monitor in [localMouseMonitor, globalMouseMonitor, localKeyMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        localMouseMonitor = nil
        globalMouseMonitor = nil
        localKeyMonitor = nil
    }

    private func handlePotentialDismiss(event: NSEvent) {
        guard isShown else { return }
        // Clicking the first-run callout dismisses the callout, not the panel.
        if event.window is FirstRunCalloutWindow { return }
        let point = screenPoint(for: event)
        if panel.frame.contains(point) || statusItemScreenRect.contains(point) {
            return
        }
        hide()
    }

    private func screenPoint(for event: NSEvent) -> NSPoint {
        if let window = event.window {
            return window.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
        }
        return NSEvent.mouseLocation
    }
}
