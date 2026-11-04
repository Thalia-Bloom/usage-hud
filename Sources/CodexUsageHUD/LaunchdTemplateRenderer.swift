import Foundation

enum LaunchdTemplateRenderer {
    struct Context: Equatable {
        var home: String
        var stateDir: String
        var binDir: String
        var supportDir: String
        var appExecutable: String
    }

    /// Every rendered job names the app, so System Settings › Login Items
    /// lists "Usage HUD" instead of "bash".
    static let associatedBundleIdentifier = "com.codexusagehud.app"

    /// Prefix of every job's `bash -c` script (launchd/*.plist). `$0` is the
    /// job label and `$1` the recorded app executable, both passed as their
    /// own ProgramArguments so no path is ever spliced into shell source.
    /// When the app is gone (Trash), the job waits 10 seconds (an update that
    /// swaps the bundle in place), checks again, then deletes its own plist,
    /// boots itself out and exits 0.
    static let selfRetireGuard =
        #"app="$1"; [ -e "$app" ] || /bin/sleep 10; if [ ! -e "$app" ]; then /bin/rm -f "$HOME/Library/LaunchAgents/$0.plist"; /bin/launchctl bootout "gui/$(/usr/bin/id -u)/$0" 2>/dev/null; exit 0; fi; "#

    static func render(_ template: String, context: Context) -> String {
        // Values land inside XML <string> elements; a path with "&" or "<"
        // must not break the plist. Shell quoting is not needed: the app path
        // is its own argument and the other paths sit inside double quotes.
        template
            .replacingOccurrences(of: "%%APP_EXECUTABLE%%", with: xmlEscaped(context.appExecutable))
            .replacingOccurrences(of: "%%BIN_DIR%%", with: xmlEscaped(context.binDir))
            .replacingOccurrences(of: "%%SUPPORT_DIR%%", with: xmlEscaped(context.supportDir))
            .replacingOccurrences(of: "%%STATE_DIR%%", with: xmlEscaped(context.stateDir))
            .replacingOccurrences(of: "%%HOME%%", with: xmlEscaped(context.home))
    }

    static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func sourceContainsPlaceholderLeak(_ template: String, forbidden: String) -> Bool {
        template.contains(forbidden)
    }
}
