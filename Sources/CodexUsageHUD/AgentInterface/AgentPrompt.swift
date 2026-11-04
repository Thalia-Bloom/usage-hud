import AppKit
import Foundation

/// The onboarding prompt a user pastes into any agent session (Claude Code,
/// Codex, Gemini CLI, Cursor…). Generated with this Mac's real absolute
/// paths, quoted for each place they land (shell, TOML, JSON). Plain and
/// honest: every step is visible, the instruction-file edit needs the
/// user's yes, and the agent must show every change it made.
enum AgentPrompt {
    static let serverName = "usage-hud"

    /// The binary that answers `status` / `mcp`: the running executable,
    /// which inside the app bundle is `…/Usage HUD.app/Contents/MacOS/CodexUsageHUD`.
    static func currentExecutablePath() -> String {
        if let url = Bundle.main.executableURL {
            return url.resolvingSymlinksInPath().standardizedFileURL.path
        }
        let argv0 = CommandLine.arguments.first ?? "CodexUsageHUD"
        return URL(fileURLWithPath: argv0).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func forThisMac() -> String {
        text(executablePath: currentExecutablePath(), home: UsagePaths.home.path)
    }

    static func copyToPasteboard(_ prompt: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
    }

    // MARK: Quoting

    /// POSIX shell word: bare when it is plainly safe, otherwise single-quoted
    /// with embedded single quotes written as '\''.
    static func shellQuote(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./=:@%+,")
        if !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A JSON string literal, quotes included.
    static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }

    /// A TOML basic string literal, quotes included.
    static func tomlString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: Text

    static func text(executablePath: String, home: String) -> String {
        let cmd = shellQuote(executablePath)
        let homeURL = URL(fileURLWithPath: home)
        func path(_ relative: String) -> String { homeURL.appendingPathComponent(relative).path }
        let codexConfig = path(".codex/config.toml")
        let geminiSettings = path(".gemini/settings.json")
        let cursorDir = path(".cursor")
        let cursorConfig = path(".cursor/mcp.json")
        let jsonEntry = "\(jsonString(serverName)): { \"command\": \(jsonString(executablePath)), \"args\": [\"mcp\"] }"

        return """
        Please connect my coding agents to Usage HUD, the menu-bar app on this Mac that shows how much of each AI plan's limits I have used (Claude, Codex, Gemini, Grok, local models). Its command line and MCP server are read-only: they read local files, need no keys, and send nothing anywhere.

        The Usage HUD command on this Mac:
        \(cmd)

        1. Check that it works by running:
           \(cmd) status
           It should print one line per plan. If it says there are no readings yet, run:
           \(cmd) setup
           That finds the coding tools on this Mac, installs their background refresh and takes a first reading, the same as the Set up button. It needs no keys or logins. Read the next action it prints for each plan and tell me those, then continue.

        2. Add the MCP server, named \(serverName), to each agent CLI installed here. Run `command -v claude codex gemini` and skip any that are missing. If an agent already has a server named \(serverName), leave it alone.
           - Claude Code. Check: claude mcp get \(serverName)
             Add: claude mcp add --scope user \(serverName) -- \(cmd) mcp
           - Codex. Check: codex mcp get \(serverName)
             Add: codex mcp add \(serverName) -- \(cmd) mcp
             If `codex mcp` does not exist, append this to \(shellQuote(codexConfig)) instead:
             [mcp_servers.\(serverName)]
             command = \(tomlString(executablePath))
             args = ["mcp"]
           - Gemini CLI. Check: gemini mcp list
             Add: gemini mcp add --scope user \(serverName) \(cmd) mcp
             If that fails, add this entry inside "mcpServers" in \(shellQuote(geminiSettings)), keeping everything already there:
             \(jsonEntry)
             Gemini CLI starts MCP servers only in folders I have trusted, so `gemini mcp list` may show it as disabled here.
           - Cursor. If \(shellQuote(cursorDir)) exists, add the same entry inside "mcpServers" in \(shellQuote(cursorConfig)), keeping everything already there.

        3. Ask me: "Add a two-line Usage HUD rule to your agents' global instructions?" Only if I say yes, append these two lines to the file of each agent you set up (create the file if it is missing, and skip it if the lines are already there): \(shellQuote(path(".claude/CLAUDE.md"))) for Claude Code, \(shellQuote(path(".codex/AGENTS.md"))) for Codex, \(shellQuote(path(".gemini/GEMINI.md"))) for Gemini CLI.
           - Before long or parallel work, check Usage HUD: call the \(serverName) MCP tool which_plan_has_room, or run \(cmd) room
           - If your plan is running hot or nearly out, tell the user and name the plan that has room.

        4. Show me every change you made: each command you ran and its result, and each file you edited with the exact lines you added. Then tell me to restart any open agent sessions so they load the new server.

        To undo later: claude mcp remove --scope user \(serverName); codex mcp remove \(serverName); gemini mcp remove --scope user \(serverName); then delete the two lines.
        """
    }
}
