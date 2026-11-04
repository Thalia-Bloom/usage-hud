import AppKit

extension Notification.Name {
    /// Posted by "Check for Updates…" in the menu-bar menu and the app menu.
    /// The updater (Sparkle) listens for it; the menu item is always shown.
    static let usageHUDCheckForUpdates = Notification.Name("usageHUDCheckForUpdates")
}

/// Target for every app-shell menu item. NSMenuItem holds its target weakly,
/// so the app delegate keeps one of these alive for the life of the app.
@MainActor
final class AppMenuActions: NSObject {
    var openPanel: () -> Void = {}
    var refresh: () -> Void = {}
    var canRefresh: () -> Bool = { true }

    @objc func openPanelAction(_ sender: Any?) { openPanel() }
    @objc func refreshAction(_ sender: Any?) { refresh() }

    @objc func openSettingsAction(_ sender: Any?) {
        NotificationCenter.default.post(name: .usageHUDOpenSettings, object: nil)
    }

    @objc func checkForUpdatesAction(_ sender: Any?) {
        NotificationCenter.default.post(name: .usageHUDCheckForUpdates, object: nil)
    }

    @objc func helpAction(_ sender: Any?) {
        NotificationCenter.default.post(name: .usageHUDOpenSettings, object: nil, userInfo: ["pane": SettingsPane.help.rawValue])
    }

    @objc func aboutAction(_ sender: Any?) { AppMenu.showAbout() }

    @objc func quitAction(_ sender: Any?) { NSApp.terminate(sender) }
}

extension AppMenuActions: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(refreshAction(_:)) { return canRefresh() }
        return true
    }
}

enum AppMenu {
    /// One row of the menu-bar item's right-click menu. Pure so the order,
    /// titles and shortcuts are testable without AppKit tracking a menu.
    struct Entry: Equatable {
        enum Command: Equatable { case openPanel, refresh, settings, checkForUpdates, help, about, quit }
        var title: String
        var keyEquivalent: String
        var command: Command?   // nil = separator

        static let separator = Entry(title: "", keyEquivalent: "", command: nil)
    }

    static let appName = AppInfo.productName

    static var statusEntries: [Entry] {
        [
            Entry(title: "Open \(appName)", keyEquivalent: "", command: .openPanel),
            Entry(title: "Refresh", keyEquivalent: "r", command: .refresh),
            .separator,
            Entry(title: "Settings\u{2026}", keyEquivalent: ",", command: .settings),
            Entry(title: "Check for Updates\u{2026}", keyEquivalent: "", command: .checkForUpdates),
            Entry(title: "Help and Support", keyEquivalent: "", command: .help),
            Entry(title: "About \(appName)", keyEquivalent: "", command: .about),
            .separator,
            Entry(title: "Quit \(appName)", keyEquivalent: "q", command: .quit),
        ]
    }

    @MainActor
    static func statusMenu(actions: AppMenuActions) -> NSMenu {
        let menu = NSMenu(title: appName)
        for entry in statusEntries {
            guard let command = entry.command else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: entry.title, action: selector(for: command), keyEquivalent: entry.keyEquivalent)
            item.target = actions
            menu.addItem(item)
        }
        return menu
    }

    private static func selector(for command: Entry.Command) -> Selector {
        switch command {
        case .openPanel: return #selector(AppMenuActions.openPanelAction(_:))
        case .refresh: return #selector(AppMenuActions.refreshAction(_:))
        case .settings: return #selector(AppMenuActions.openSettingsAction(_:))
        case .checkForUpdates: return #selector(AppMenuActions.checkForUpdatesAction(_:))
        case .help: return #selector(AppMenuActions.helpAction(_:))
        case .about: return #selector(AppMenuActions.aboutAction(_:))
        case .quit: return #selector(AppMenuActions.quitAction(_:))
        }
    }

    // MARK: - Main menu

    /// An LSUIElement app never shows a menu bar, but AppKit still routes key
    /// equivalents through `NSApp.mainMenu` while one of its windows is key.
    /// Without this, ⌘C/⌘V/⌘A/⌘Z do nothing in Settings text fields and ⌘W
    /// cannot close a window.
    @MainActor
    static func installMainMenu(actions: AppMenuActions) {
        let main = NSMenu(title: "Main Menu")

        let appMenu = NSMenu(title: appName)
        appMenu.addItem(item("About \(appName)", #selector(AppMenuActions.aboutAction(_:)), "", target: actions))
        appMenu.addItem(item("Check for Updates\u{2026}", #selector(AppMenuActions.checkForUpdatesAction(_:)), "", target: actions))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings\u{2026}", #selector(AppMenuActions.openSettingsAction(_:)), ",", target: actions))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"))
        let hideOthers = item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"))
        main.addItem(submenu(appMenu))

        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        let redo = item("Redo", Selector(("redo:")), "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Delete", #selector(NSText.delete(_:)), ""))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        main.addItem(submenu(edit))

        let window = NSMenu(title: "Window")
        window.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:)), ""))
        main.addItem(submenu(window))

        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }

    @MainActor
    private static func item(_ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }

    @MainActor
    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let holder = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    // MARK: - About

    static var resolvedBuild: String {
        let bundle = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let bundle, !bundle.isEmpty { return bundle }
        return AppInfo.buildNumber
    }

    /// "Free. Made by Thalia Bloom." over a link to the site, centered and in
    /// the small secondary style the standard About panel uses for credits.
    static func aboutCredits() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 4
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let credits = NSMutableAttributedString(
            string: "Free. Made by Thalia Bloom.\n",
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]
        )
        credits.append(NSAttributedString(
            string: AppInfo.supportURL.host ?? "hud.thaliabloom.com",
            attributes: [.font: font, .link: AppInfo.supportURL, .paragraphStyle: paragraph]
        ))
        return credits
    }

    /// An accessory app is never frontmost on its own. macOS 14's
    /// cooperative `activate()` may decline when the request does not follow
    /// a click in this app (VoiceOver, scripts), which leaves About or an
    /// alert behind other windows, so this asks the way Settings does.
    @MainActor
    static func bringAppForward() {
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    static func showAbout() {
        bringAppForward()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: appName,
            .applicationVersion: AppInfo.resolvedMarketingVersion,
            .version: resolvedBuild,
            .credits: aboutCredits(),
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "\u{00A9} 2026 \(AppInfo.legalName)",
        ])
    }
}
