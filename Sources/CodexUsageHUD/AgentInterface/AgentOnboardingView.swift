import AppKit
import SwiftUI

/// "Connect your agents": the onboarding prompt, read-only and selectable,
/// with one Copy button. Built from system styles only so it sits in
/// Settings or on the Set up card without depending on panel theming.
struct AgentOnboardingView: View {
    let prompt: String
    var showsTitle = true
    @State private var copied = false

    init(prompt: String = AgentPrompt.forThisMac(), showsTitle: Bool = true) {
        self.prompt = prompt
        self.showsTitle = showsTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsTitle {
                Text("Connect your agents")
                    .font(.headline)
            }
            Text("Paste this into Claude Code, Codex, Gemini CLI or any agent session. It connects them to Usage HUD and shows you every change.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(prompt)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 120, maxHeight: 220)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )
            .accessibilityLabel("Setup prompt for agents")

            HStack(spacing: 8) {
                Button(copied ? "Copied" : "Copy prompt") {
                    AgentPrompt.copyToPasteboard(prompt)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }
                .buttonStyle(.borderedProminent)
                .help("Copies the setup prompt to the clipboard.")
                Spacer()
            }
        }
    }
}
