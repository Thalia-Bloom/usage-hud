import AppKit
import SwiftUI

/// On-demand "Activity" window: sessions from today and the last five hours,
/// read from the coding tools' session logs. Owns its ActivityState so its
/// timer only runs while the window is open; the menu panel stays compact.
/// Frame is restored from defaults, the window survives close (not released),
/// and the SwiftUI content enforces the minimum size alongside AppKit.
///
/// Keyboard: the HUD is an accessory app with no File menu, so Cmd-W, Cmd-R
/// and Escape are handled by this window itself and reach nothing else.
@MainActor
final class ActivityWindowController: NSWindowController, NSWindowDelegate {
    static let defaultContentSize = NSSize(width: 900, height: 640)
    static let minimumContentSize = NSSize(width: 720, height: 460)
    private static let frameAutosaveName = "UsageHUDActivityWindow.v2"

    let state: ActivityState

    convenience init() {
        self.init(state: ActivityState())
    }

    init(state: ActivityState) {
        self.state = state

        let host = NSHostingView(rootView: ActivityView(state: state))
        host.sizingOptions = []   // window frame is ours; SwiftUI still declares its min size
        host.frame = NSRect(origin: .zero, size: Self.defaultContentSize)

        let window = ActivityWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Activity"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentMinSize = Self.minimumContentSize
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.isMovableByWindowBackground = false
        window.onRefresh = { state.refresh(forceScan: true) }

        let restored = window.setFrameUsingName(Self.frameAutosaveName)
        window.setFrameAutosaveName(Self.frameAutosaveName)
        if !restored { window.center() }

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Bring the window forward and start its refresh timer. Safe to call repeatedly.
    func show() {
        guard let window else { return }
        state.start()
        window.makeKeyAndOrderFront(nil)
        if window.firstResponder === window, let content = window.contentView {
            // Hand focus to the SwiftUI content so Tab and the arrow keys work
            // without a click.
            window.makeFirstResponder(content)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Keyboard

    enum KeyAction: Equatable, Sendable {
        case close, refresh
    }

    /// Pure mapping from a key event to a window action. Only plain Escape
    /// (virtual key code 53), Cmd-W and Cmd-R qualify; any extra modifier
    /// (Shift, Option, Control) is left alone so nothing else's shortcut is
    /// shadowed.
    nonisolated static func keyAction(
        characters: String?,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) -> KeyAction? {
        let relevant = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if relevant.isEmpty {
            return keyCode == 53 ? .close : nil
        }
        guard relevant == .command, let characters else { return nil }
        switch characters.lowercased() {
        case "w": return .close
        case "r": return .refresh
        default: return nil
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Closing hides the window; stop polling so a hidden window costs nothing.
        state.stop()
    }
}

/// NSWindow that answers the three keys itself. Key equivalents are checked
/// before the content view sees them, so nothing fires twice; plain Escape
/// arrives either as `keyDown` (window is first responder) or as
/// `cancelOperation` (a focused list interpreted it).
private final class ActivityWindow: NSWindow {
    var onRefresh: (@MainActor () -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handle(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handle(event) { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        closeIfVisible()
    }

    private func handle(_ event: NSEvent) -> Bool {
        let action = ActivityWindowController.keyAction(
            characters: event.charactersIgnoringModifiers,
            modifiers: event.modifierFlags,
            keyCode: event.keyCode
        )
        switch action {
        case .close:
            closeIfVisible()
            return true
        case .refresh:
            onRefresh?()
            return true
        case nil:
            return false
        }
    }

    private func closeIfVisible() {
        guard isVisible else { return }
        performClose(nil)
    }
}
