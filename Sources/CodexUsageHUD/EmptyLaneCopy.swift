import Foundation

/// Per-provider copy when no snapshot has landed yet. Plain words, no
/// product or person names beyond the tool the lane reads.
enum EmptyLaneCopy {
    static func line(for provider: String) -> String {
        line(
            for: provider,
            nodeAvailable: RuntimeDependencies.nodeAvailable,
            pythonAvailable: RuntimeDependencies.python3Available
        )
    }

    static func line(for provider: String, nodeAvailable: Bool, pythonAvailable: Bool) -> String {
        switch provider.lowercased() {
        case "local":
            return "Start Ollama"
        // Claude and Codex are read in-app when Node.js or Python is missing.
        case "claude":
            return "Sign in to Claude Code, then Refresh"
        case "codex":
            return "Run one Codex session, then Refresh"
        case "gemini":
            if !nodeAvailable {
                return "Gemini needs Node.js. Install it from nodejs.org."
            }
            return "Sign in to Antigravity (agy), then Refresh"
        case "grok":
            if !nodeAvailable {
                return "Grok needs Node.js. Install it from nodejs.org."
            }
            return "Sign in to Grok, then Refresh"
        default:
            return "\(UsageInsights.label(for: provider)): Refresh after you sign in"
        }
    }
}
