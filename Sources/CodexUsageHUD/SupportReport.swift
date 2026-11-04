import Foundation

/// A deliberately small projection of diagnostics. Raw details never enter a
/// report: they can contain file paths, account information or tool output.
enum SupportReport {
    static func emailURL(report: String? = nil) -> URL {
        var url = URLComponents()
        url.scheme = "mailto"
        url.path = "support@thaliabloom.com"
        url.queryItems = [
            URLQueryItem(name: "subject", value: "Usage HUD help"),
            URLQueryItem(name: "body", value: report ?? "What I expected:\n\nWhat happened:\n\nUsage HUD version: \(AppInfo.resolvedMarketingVersion)\nmacOS version: \(ProcessInfo.processInfo.operatingSystemVersionString)\nAffected tool:\n")
        ]
        return url.url!
    }

    struct Check: Equatable {
        let status: String
        let name: String
        var issue: Issue? = nil
    }

    /// Only these known machine statuses may leave the raw diagnostics view.
    enum Issue: String {
        case rateLimited = "rate_limited", unauthorized, noCredential = "no_credential", tokenExpired = "token_expired", offline, unparsed

        var label: String {
            switch self {
            case .rateLimited: return "provider asked us to wait"
            case .unauthorized, .noCredential: return "sign-in needed"
            case .tokenExpired: return "sign-in paused until Claude Code runs"
            case .offline: return "connection unavailable"
            case .unparsed: return "usage response not understood"
            }
        }
    }

    static func checks(_ output: String) -> [Check] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let words = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard words.count == 2, ["OK", "WARN", "FAIL"].contains(String(words[0])) else { return nil }
            let parts = words[1].split(separator: ":", maxSplits: 1)
            guard let rawName = parts.first else { return nil }
            let name = rawName.trimmingCharacters(in: .whitespaces)
            let token = parts.count == 2 ? parts[1].split(separator: "·").first?.trimmingCharacters(in: .whitespaces) : nil
            let issue = name == "claude official /usage" ? token.flatMap(Issue.init(rawValue:)) : nil
            return Check(status: String(words[0]), name: name, issue: issue)
        }
    }

    static func label(_ name: String) -> String {
        switch name {
        case "com.codexusagehud.app": return "App process"
        case "state dir": return "Local storage"
        case "codex home": return "Codex local storage"
        case "codex sessions", "session logs", "rate-limit event": return "Codex session readings"
        case "claude budget guard hook": return "Claude optional usage guard"
        case "fable weekly reading": return "Claude model-specific weekly reading"
        default:
            for (id, title) in [("claude", "Claude"), ("codex", "Codex"), ("gemini", "Gemini"), ("grok", "Grok"), ("local", "Local models")] {
                if name == id { return title }
                let suffixes = ["snapshot": "saved reading", "health": "reading freshness", "windows": "usage windows",
                                "writer log": "background errors", "official /usage": "usage check", "fetch interpreter": "connection setup",
                                "statusline tap": "optional live readings", "statusline command": "optional status line",
                                "budget guard": "optional usage guard", "budget mode": "usage estimate"]
                if let suffix = suffixes.first(where: { name == "\(id) \($0.key)" }) { return "\(title) \(suffix.value)" }
                if name == "com.codexusagehud.\(id)-writer" { return "\(title) background refresh" }
            }
            if ["com.codexusagehud.refresh", "com.codexusagehud.live-scraper"].contains(name) { return "Background refresh" }
            return "Other health check"
        }
    }

    static func nextSteps(_ output: String) -> [String] {
        let problems = checks(output).filter { $0.status != "OK" }
        let claudeRateLimited = problems.contains { $0.issue == .rateLimited }
        var steps: [String] = []
        for check in problems {
            let next: String
            if check.name == "com.codexusagehud.app" {
                next = "Open Usage HUD from Applications, then run diagnostics again. If it is already open, quit and reopen it."
            } else if claudeRateLimited && (check.name.hasPrefix("claude") || check.name == "fable weekly reading") {
                next = "Claude: usage requests are temporarily rate-limited. Keep Usage HUD open for automatic retries. No sign-in or setup change is needed. If readings stay old after the cooldown, run diagnostics again."
            } else if check.name.hasPrefix("claude statusline") {
                next = "Claude: the live status-line integration is optional. Open Help and support to check its configuration; official usage refresh does not require it."
            } else if check.name == "claude budget guard hook" {
                next = "Claude: the usage guard integration is optional. Open Help and support to check its configuration; official usage refresh does not require it."
            } else if check.name.hasPrefix("claude") {
                next = "Claude: open Claude Code and check that you are signed in, then choose Refresh now."
            } else if check.name.hasPrefix("codex") || check.name == "session logs" || check.name == "rate-limit event" {
                next = "Codex: open Codex and check that you are signed in, then choose Refresh now."
            } else if check.name.hasPrefix("gemini") || check.name.hasPrefix("grok") {
                next = "Gemini or Grok: check the tool's sign-in and that Node.js 18 or later is installed, then choose Refresh now."
            } else if check.name.hasPrefix("com.codexusagehud.") {
                next = "Background refresh: choose Set up again, then run diagnostics again."
            } else {
                next = "Open Help and support for recovery steps. If the problem continues, preview and copy a support report."
            }
            if !steps.contains(next) { steps.append(next) }
        }
        return steps
    }

    static func text(_ output: String, version: String, build: String, system: String) -> String {
        let rows = checks(output).map { check in
            "\(check.status)  \(label(check.name))" + (check.issue.map { " — \($0.label)" } ?? "")
        }
        return (["Usage HUD support report", "Version: \(version) (\(build))", "macOS: \(system)", "",
                 "Health checks (details omitted):"] + (rows.isEmpty ? ["No completed checks. Open Help and support for setup steps."] : rows) +
                ["", "This report contains no raw logs, file paths, account names, prompts, usage amounts or credentials.",
                 "", "What I expected:", "What happened:"]).joined(separator: "\n")
    }
}
