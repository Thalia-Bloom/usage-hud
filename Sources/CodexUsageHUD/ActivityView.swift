import AppKit
import SwiftUI

// ============================================================================
//  Activity: which coding sessions ran today and in the last five hours,
//  what each one used, what that is worth at API prices, and which one is
//  spending fastest right now. Built from the tools' own session logs, so
//  it works on every Mac with Claude Code, Codex or Gemini CLI.
// ============================================================================

@MainActor
final class ActivityState: ObservableObject {
    @Published private(set) var summary: ActivitySummary?
    @Published private(set) var updatedAt: Date?
    private var timer: Timer?
    private var loading = false

    /// Starts the window's refresh. The scan itself runs on the token
    /// index's own queue; this only reads its last result.
    func start() {
        refresh()
        timer?.invalidate()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh(forceScan: Bool = false) {
        guard !loading else { return }
        loading = true
        Task {
            let summary = await Task.detached(priority: .utility) { () -> ActivitySummary? in
                let roots = TokenLogRoots.current
                let index = TokenUsageIndex.shared
                if forceScan {
                    return ActivitySummary.make(scan: index.scan(roots: roots, maxAge: 5), now: Date())
                }
                index.refreshInBackground(roots: roots)
                guard let scan = index.latest(), scan.roots == roots else { return nil }
                return SpendMemo.shared.activity(scan: scan, now: Date())
            }.value
            if let summary {
                self.summary = summary
                self.updatedAt = summary.generatedAt
            }
            self.loading = false
        }
    }

    /// Blocking read for the offscreen renderer.
    func refreshNow(now: Date = Date()) {
        let scan = TokenUsageIndex.shared.scan(roots: .current, now: now)
        summary = ActivitySummary.make(scan: scan, now: now)
        updatedAt = now
    }
}

struct ActivityView: View {
    @ObservedObject var state: ActivityState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 14)
            Rectangle().fill(ActivityPalette.hair).frame(height: 0.5)
            content
            Rectangle().fill(ActivityPalette.hair).frame(height: 0.5)
            footer
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
        }
        .frame(minWidth: ActivityWindowController.minimumContentSize.width,
               minHeight: ActivityWindowController.minimumContentSize.height,
               alignment: .topLeading)
        .background(ActivityPalette.base)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Activity")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ActivityPalette.ink)
                Text("Today and the last 5 hours, from the session logs on this Mac")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(ActivityPalette.ink3)
            }
            Spacer(minLength: 12)
            if let updated = state.updatedAt {
                (Text("Updated ") + Text(updated, style: .time))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ActivityPalette.ink3)
            }
            Button {
                state.refresh(forceScan: true)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(ActivityPalette.ink)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .overlay(Capsule().strokeBorder(ActivityPalette.hair, lineWidth: 0.5))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Read the session logs again now (⌘R)")
        }
    }

    @ViewBuilder private var content: some View {
        if let summary = state.summary {
            if summary.sessions.isEmpty {
                ActivityEmptyView(noLogs: summary.status == "no_logs")
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 18) {
                        TopBurnerCard(summary: summary)
                        ForEach(summary.groups) { group in
                            ToolGroupView(group: group, now: summary.generatedAt)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                }
            }
        } else {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading session logs…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ActivityPalette.ink3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        Text("API value is what these tokens would cost at pay-per-use API prices (checked Oct 1, 2026). You are not billed for it. Tokens include cache reads and writes. Only project folder names and model names are shown.")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(ActivityPalette.ink3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Pieces

private struct TopBurnerCard: View {
    let summary: ActivitySummary

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                if let top = summary.topBurner {
                    (Text("Top burner now  ").foregroundStyle(ActivityPalette.ink3)
                     + Text("\(top.toolName) · \(top.project)").foregroundStyle(ActivityPalette.ink)
                     + Text(" · ").foregroundStyle(ActivityPalette.ink3)
                     + Text(SpendDisplay.perHour(top.usdPerHour)).foregroundStyle(ActivityPalette.ink).fontWeight(.semibold))
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("\(top.model) · \(SpendDisplay.tokens(top.tokensPerHour)) tokens in the last hour · not billed")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ActivityPalette.ink3)
                        .lineLimit(1)
                } else {
                    Text("Nothing is spending right now")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(ActivityPalette.ink2)
                    Text("No session used tokens in the last hour.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ActivityPalette.ink3)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 5) {
                Text(SpendDisplay.money(summary.totalAPIValueUSD))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(ActivityPalette.ink)
                    .monospacedDigit()
                Text("\(SpendDisplay.tokens(summary.totalTokens)) tokens · \(summary.sessions.count) \(summary.sessions.count == 1 ? "session" : "sessions")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ActivityPalette.ink3)
                    .monospacedDigit()
            }
            .help("API value of every session shown here. Not billed.")
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        .help("The session spending fastest: its API value over the last 60 minutes.")
    }
}

private enum Columns {
    static let model: CGFloat = 150
    static let last: CGFloat = 74
    static let tokens: CGFloat = 68
    static let value: CGFloat = 76
    static let burn: CGFloat = 120
    static let dot: CGFloat = 18
}

private struct ToolGroupView: View {
    let group: ActivitySummary.ToolGroup
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(ActivityPalette.tool(group.tool)).frame(width: 8, height: 8)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(group.toolName)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(ActivityPalette.ink)
                Text("\(group.sessions.count) \(group.sessions.count == 1 ? "session" : "sessions")")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(ActivityPalette.ink3)
                Spacer(minLength: 8)
                (Text(SpendDisplay.money(group.apiValueUSD)).foregroundStyle(ActivityPalette.ink2)
                 + Text(" API value").foregroundStyle(ActivityPalette.ink3)
                 + Text(group.usdPerHour > 0.005 ? " · \(SpendDisplay.perHour(group.usdPerHour)) now" : "").foregroundStyle(ActivityPalette.ink2))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
            .padding(.bottom, 8)

            ColumnHeader()
            ForEach(group.sessions) { session in
                SessionRow(session: session, now: now)
                    .overlay(alignment: .top) { Rectangle().fill(ActivityPalette.hairSoft).frame(height: 0.5) }
            }
        }
    }
}

private struct ColumnHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: Columns.dot, height: 1)
            Text("Project").frame(maxWidth: .infinity, alignment: .leading)
            Text("Model").frame(width: Columns.model, alignment: .leading)
            Text("Last active").frame(width: Columns.last, alignment: .trailing)
            Text("Tokens").frame(width: Columns.tokens, alignment: .trailing)
            Text("API value").frame(width: Columns.value, alignment: .trailing)
            Text("Last hour").frame(width: Columns.burn, alignment: .trailing)
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(ActivityPalette.ink3)
        .padding(.vertical, 5)
        .accessibilityHidden(true)
    }
}

private struct SessionRow: View {
    let session: ActivitySummary.Session
    let now: Date

    private var live: Bool { now.timeIntervalSince(session.lastActiveAt) < 10 * 60 }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(ActivityPalette.tool(session.tool).opacity(live ? 1 : 0.45))
                    .frame(width: 7, height: 7)
                if live {
                    Circle().fill(ActivityPalette.tool(session.tool).opacity(0.22)).frame(width: 13, height: 13)
                }
            }
            .frame(width: Columns.dot)
            .help(live ? "Active in the last 10 minutes" : "")
            HStack(spacing: 6) {
                Text(session.project)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(ActivityPalette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if session.helpers > 0 {
                    Text("+\(session.helpers) \(session.helpers == 1 ? "helper" : "helpers")")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(ActivityPalette.ink3)
                        .lineLimit(1)
                        .help("Subagents or helper threads this session started, counted in its totals.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(session.model)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(ActivityPalette.ink2)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Columns.model, alignment: .leading)
                .help(session.models.count > 1 ? "Models: \(session.models.joined(separator: ", "))" : session.model)
            Text(SpendDisplay.ago(session.lastActiveAt, now: now))
                .foregroundStyle(live ? ActivityPalette.ink : ActivityPalette.ink2)
                .frame(width: Columns.last, alignment: .trailing)
            Text(SpendDisplay.tokens(session.tokens))
                .foregroundStyle(ActivityPalette.ink2)
                .frame(width: Columns.tokens, alignment: .trailing)
            Text(SpendDisplay.money(session.apiValueUSD) + (session.estimated ? "*" : ""))
                .foregroundStyle(ActivityPalette.ink)
                .frame(width: Columns.value, alignment: .trailing)
                .help(session.estimated ? "* Some of this session's models are not on the vendor's price list, so they are priced like the closest listed model." : "API value at pay-per-use prices. Not billed.")
            burn
                .frame(width: Columns.burn, alignment: .trailing)
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .monospacedDigit()
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder private var burn: some View {
        if session.usdPerHour > 0.005 {
            VStack(alignment: .trailing, spacing: 1) {
                Text(SpendDisplay.perHour(session.usdPerHour))
                    .foregroundStyle(ActivityPalette.ink)
                Text("\(SpendDisplay.tokens(session.tokensPerHour)) tok/h")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(ActivityPalette.ink3)
            }
        } else {
            Text("idle")
                .foregroundStyle(ActivityPalette.ink3)
        }
    }

    private var accessibilityText: String {
        var parts = ["\(session.toolName), \(session.project)", session.model,
                     "last active \(SpendDisplay.ago(session.lastActiveAt, now: now))",
                     "\(SpendDisplay.tokens(session.tokens)) tokens",
                     "\(SpendDisplay.money(session.apiValueUSD)) API value"]
        if session.usdPerHour > 0.005 { parts.append("spending \(SpendDisplay.perHour(session.usdPerHour))") }
        return parts.joined(separator: ", ")
    }
}

private struct ActivityEmptyView: View {
    let noLogs: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(ActivityPalette.ink3)
            Text(noLogs ? "No session logs on this Mac yet" : "Nothing ran today or in the last 5 hours")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ActivityPalette.ink)
            Text("Each Claude Code, Codex or Gemini CLI session shows here as soon as it writes to its log: the project folder, the model, when it was last active, its tokens, what they would cost at API prices, and how fast it is spending.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ActivityPalette.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The panel's graphite palette, for the Activity window.
private enum ActivityPalette {
    static let base = Color(.sRGB, red: 0x15 / 255, green: 0x17 / 255, blue: 0x1D / 255, opacity: 1)
    static let ink = Color(.sRGB, red: 0xF3 / 255, green: 0xF4 / 255, blue: 0xF8 / 255, opacity: 1)
    static let ink2 = ink.opacity(0.72)
    static let ink3 = ink.opacity(0.52)
    static let hair = Color.white.opacity(0.09)
    static let hairSoft = Color.white.opacity(0.06)

    static func tool(_ id: String) -> Color {
        switch id {
        case "claude": return Color(.sRGB, red: 0xE0 / 255, green: 0x7A / 255, blue: 0x5B / 255, opacity: 1)
        case "codex": return Color(.sRGB, red: 0x5F / 255, green: 0xD3 / 255, blue: 0xC4 / 255, opacity: 1)
        case "gemini": return Color(.sRGB, red: 0x6F / 255, green: 0x8B / 255, blue: 0xF5 / 255, opacity: 1)
        default: return ink2
        }
    }
}
