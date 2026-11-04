import AppKit
import SwiftUI

// MARK: - Panes

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, lanes, plans, badge, agents, help, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .lanes: return "Lanes"
        case .plans: return "Plans"
        case .badge: return "Badge"
        case .agents: return "Agents"
        case .help: return "Help"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .lanes: return "chart.bar.doc.horizontal"
        case .plans: return "creditcard"
        case .badge: return "rosette"
        case .agents: return "terminal"
        case .help: return "questionmark.circle"
        case .about: return "info.circle"
        }
    }
}

struct SettingsPaneView: View {
    let pane: SettingsPane
    @ObservedObject var state: UsageState
    @ObservedObject var jobs: BackgroundJobsModel

    var body: some View {
        switch pane {
        case .general: GeneralSettingsPane(state: state, jobs: jobs)
        case .lanes: LanesSettingsPane(state: state, jobs: jobs)
        case .plans: PlansSettingsPane(state: state)
        case .badge: BadgeSettingsPane(state: state)
        case .agents: AgentsSettingsPane()
        case .help: HelpSettingsPane(state: state, jobs: jobs)
        case .about: AboutSettingsPane()
        }
    }
}

// MARK: - Background jobs model

/// Open at login, Set up, Refresh, Detect again, Diagnostics and Remove for
/// the Settings window. Every result has a plain headline; the raw report
/// (launchctl lines, exit codes) only appears behind "Show details".
@MainActor
final class BackgroundJobsModel: ObservableObject {
    struct Result: Equatable {
        var headline: String
        var lines: [String] = []
        var isWarning = false
        var details = ""
        var supportReport: String?
    }

    enum Action { case setUp, refreshNow, detectAgain, diagnostics, remove }

    @Published private(set) var busy = false
    @Published private(set) var activity = ""
    @Published private(set) var result: Result?
    @Published var showDetails = false
    @Published private(set) var openAtLogin = false
    @Published private(set) var openAtLoginNote: String?
    @Published private(set) var installed = false
    @Published private(set) var detectionLine = ""

    init() {
        reload()
    }

    /// Reads the real state from disk: the toggle and status always match
    /// what is installed, not what was last clicked.
    func reload() {
        openAtLogin = BackgroundRefreshService.isOpenAtLoginEnabled()
        installed = BackgroundRefreshService.isInstalled()
        detectionLine = ProviderPreferences.detectionSummary().map(Self.detectionText(_:)) ?? ""
    }

    func setOpenAtLogin(_ enabled: Bool) {
        guard !busy else { return }
        openAtLogin = enabled
        openAtLoginNote = nil
        Task {
            let report = await Task.detached(priority: .userInitiated) {
                BackgroundRefreshService.setOpenAtLogin(enabled, paths: .resolved())
            }.value
            openAtLoginNote = report.blocker
            reload()
        }
    }

    /// Demo content for the offscreen Settings snapshot only.
    func showSnapshotResult(_ result: Result, expanded: Bool) {
        self.result = result
        showDetails = expanded
    }

    func run(_ action: Action, state: UsageState) {
        guard !busy else { return }
        busy = true
        showDetails = false
        activity = Self.activityText(action)
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Self.perform(action)
            }.value
            self.result = result
            busy = false
            reload()
            state.refresh()
        }
    }

    nonisolated static func perform(_ action: Action) -> Result {
        if action == .detectAgain {
            let summary = ProviderPreferences.detectAgain()
            let found = summary.foundDisplayNames
            return Result(
                headline: found.isEmpty ? "No coding tools found on this Mac." : "Found \(listText(found)).",
                lines: summary.missingLine.map { [$0] } ?? [],
                isWarning: found.isEmpty
            )
        }
        let paths = BackgroundRefreshService.Paths.resolved()
        let providers = ProviderPreferences.selection().shown.sorted()
        switch action {
        case .setUp:
            let outcome = BackgroundRefreshService.setUpAndRefresh(paths: paths, providers: providers)
            if let blocker = outcome.blocker {
                return Result(headline: "Set up didn’t run.", lines: [blocker], isWarning: true, details: outcome.report.text)
            }
            return readingResult(lanes: outcome.lanes, isSetup: true, details: outcome.report.text)
        case .refreshNow:
            let report = BackgroundRefreshService.refreshNow(paths: paths)
            let lanes = LaneSetupScoring.score(
                providers: providers,
                stateDirectory: paths.stateDirectory,
                nodeAvailable: paths.nodeAvailable,
                pythonAvailable: paths.pythonAvailable,
                codexSessionsRoot: paths.codexSessionsRoot
            )
            return readingResult(lanes: lanes, isSetup: false, details: report.text)
        case .diagnostics:
            let report = BackgroundRefreshService.runDiagnostics(paths: paths)
            return diagnosticsResult(report.text)
        case .remove:
            let report = BackgroundRefreshService.remove(paths: paths)
            return Result(
                headline: "Background refresh removed.",
                lines: ["Usage HUD won’t open at login. Run Set up to turn it back on."],
                details: report.text
            )
        case .detectAgain:
            return Result(headline: "")
        }
    }

    nonisolated static func readingResult(lanes: [LaneSetupResult], isSetup: Bool, details: String) -> Result {
        let usable = LaneSetupScoring.hasUsableData(lanes)
        let unresolved = lanes.contains { !$0.status.isSuccess }
        let headline: String
        if usable && unresolved { headline = "Some readings are ready; others need attention." }
        else if !usable { headline = "Waiting for your first reading." }
        else { headline = isSetup ? "Your readings are ready." : "Readings checked." }
        return Result(headline: headline, lines: lanes.map(\.line), isWarning: unresolved || !usable, details: details)
    }

    /// The health check prints one "OK  name: detail" / "WARN …" / "FAIL …"
    /// line per check. Count them; anything else is a message to show as is.
    nonisolated static func diagnosticsResult(_ output: String) -> Result {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let passed = lines.filter { $0.hasPrefix("OK ") }.count
        let warned = lines.filter { $0.hasPrefix("WARN") }.count
        let failed = lines.filter { $0.hasPrefix("FAIL") }.count
        guard passed + warned + failed > 0 else {
            return Result(headline: lines.first ?? "The health check printed nothing.", isWarning: true, details: output)
        }
        var parts = ["\(passed) passed"]
        if warned > 0 { parts.append("\(warned) \(warned == 1 ? "warning" : "warnings")") }
        if failed > 0 { parts.append("\(failed) \(failed == 1 ? "problem" : "problems")") }
        let headline = warned + failed == 0
            ? (passed == 1 ? "1 check passed." : "All \(passed) checks passed.")
            : "Health check: \(parts.joined(separator: " · "))."
        return Result(headline: headline, lines: SupportReport.nextSteps(output), isWarning: warned + failed > 0,
                      details: output, supportReport: SupportReport.text(output,
                        version: AppInfo.resolvedMarketingVersion, build: BackgroundRefreshService.currentBuildNumber,
                        system: ProcessInfo.processInfo.operatingSystemVersionString))
    }

    nonisolated static func detectionText(_ summary: DetectionSummary) -> String {
        [summary.foundLine, summary.missingLine].compactMap { $0 }.joined(separator: " · ")
    }

    private nonisolated static func listText(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    private static func activityText(_ action: Action) -> String {
        switch action {
        case .setUp: return "Setting up… about 10 seconds."
        case .refreshNow: return "Refreshing readings…"
        case .detectAgain: return "Looking for coding tools…"
        case .diagnostics: return "Running the health check…"
        case .remove: return "Removing background refresh…"
        }
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @ObservedObject var state: UsageState
    @ObservedObject var jobs: BackgroundJobsModel
    @State private var confirmRemove = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { jobs.openAtLogin }, set: { jobs.setOpenAtLogin($0) })) {
                    Text("Open at login")
                    Text("Starts Usage HUD in the menu bar when you log in.")
                }
                .disabled(jobs.busy)
                if let note = jobs.openAtLoginNote {
                    WarningText(note)
                }
            }

            Section {
                LabeledContent {
                    if jobs.installed {
                        Button("Set up again") { jobs.run(.setUp, state: state) }
                            .disabled(jobs.busy)
                    } else {
                        Button("Set up") { jobs.run(.setUp, state: state) }
                            .buttonStyle(.borderedProminent)
                            .disabled(jobs.busy)
                    }
                } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(jobs.installed ? Color.green : Color.secondary.opacity(0.5))
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(jobs.installed ? "On" : "Not set up")
                    }
                    Text(jobs.installed
                         ? "Checks for new readings while the panel is closed."
                         : "Installs a background refresh for the tools found. About 10 seconds.")
                }

                LabeledContent {
                    Button("Refresh now") { jobs.run(.refreshNow, state: state) }
                        .disabled(jobs.busy)
                } label: {
                    Text("Refresh readings")
                    Text("Checks for new readings. Provider retry waits still apply.")
                }

                LabeledContent {
                    Button("Detect again") { jobs.run(.detectAgain, state: state) }
                        .disabled(jobs.busy)
                        .help(ProviderPreferences.detectAgainHelp)
                } label: {
                    Text("Coding tools")
                    Text(jobs.detectionLine.isEmpty ? "Looks for Claude Code, Codex, Gemini, Grok and Ollama." : jobs.detectionLine)
                }

                LabeledContent {
                    Button("Run diagnostics") { jobs.run(.diagnostics, state: state) }
                        .disabled(jobs.busy)
                } label: {
                    Text("Health check")
                    Text("Checks each lane and background job.")
                }

                if jobs.busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(jobs.activity).foregroundStyle(.secondary)
                    }
                } else if let result = jobs.result {
                    ResultView(result: result, showDetails: $jobs.showDetails)
                }
            } header: {
                Text("Background refresh")
            }

            Section {
                LabeledContent {
                    Button("Remove…", role: .destructive) { confirmRemove = true }
                        .disabled(jobs.busy)
                } label: {
                    Text("Remove background refresh")
                    Text("Stops the background jobs and takes Usage HUD out of Login Items.")
                }
            }

            Section {
                Label {
                    Text("Usage stays on this Mac unless you publish a README badge. Turning a lane off only stops reading it; history and sign-ins stay.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lock.shield").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { jobs.reload() }
        .confirmationDialog("Remove background refresh?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { jobs.run(.remove, state: state) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This stops Usage HUD’s background jobs, deletes the helper copies it installed and removes it from Login Items, so it won’t open at login. Your usage history, settings and sign-ins stay. You can run Set up again any time.")
        }
    }
}

struct ResultView: View {
    let result: BackgroundJobsModel.Result
    @Binding var showDetails: Bool
    @State private var showSupportReport = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(result.headline).fontWeight(.medium)
            } icon: {
                Image(systemName: result.isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(result.isWarning ? Color.orange : Color.green)
            }
            ForEach(Array(result.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if result.supportReport != nil {
                HStack {
                    Button("Preview support report…") { copied = false; showSupportReport = true }
                    Link("Help and support", destination: AppInfo.supportURL)
                }
                .padding(.vertical, 4)
            }
            if !result.details.isEmpty {
                DisclosureGroup("Show details", isExpanded: $showDetails) {
                    ScrollView {
                        Text(result.details)
                            .font(.system(size: 10.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 180)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                }
                .font(.callout)
            }
        }
        .padding(.vertical, 2)
        .sheet(isPresented: $showSupportReport) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Support report").font(.title2).fontWeight(.semibold)
                Text("Review what will be copied. Nothing is sent automatically.").foregroundStyle(.secondary)
                ScrollView {
                    Text(result.supportReport ?? "")
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Link("Email this report…", destination: SupportReport.emailURL(report: result.supportReport))
                    Spacer()
                    Button("Done") { showSupportReport = false }
                        .keyboardShortcut(.cancelAction)
                    Button(copied ? "Copied" : "Copy report") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.supportReport ?? "", forType: .string)
                        copied = true
                    }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 540, height: 430)
        }
    }
}

private struct WarningText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

// MARK: - Lanes

private struct LanesSettingsPane: View {
    @ObservedObject var state: UsageState
    @ObservedObject var jobs: BackgroundJobsModel

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Lane")
                    Spacer()
                    Text("Read").frame(width: LaneColumns.toggle)
                    Text("Show").frame(width: LaneColumns.toggle)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

                ForEach(ProviderCatalog.displayProviders) { provider in
                    ProviderPreferenceRow(
                        provider: provider,
                        detected: state.snapshots.contains { $0.provider.lowercased() == provider.id }
                    )
                }
            } header: {
                Text("Lanes")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Read lets Usage HUD read a lane. Show puts it in the panel and the menu bar.")
                    if !jobs.detectionLine.isEmpty {
                        Text(jobs.detectionLine)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section {
                ResetPingCard(
                    controller: state.resetPings,
                    providers: ResetPingController.providers.filter { ProviderPreferences.selection().shown.contains($0) }
                )
            } header: {
                Text("Reset pings")
            } footer: {
                Text("One silent banner when a window you used up is confirmed back. Keep Usage HUD running. The bell on each lane in the panel turns these on too.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private enum LaneColumns {
    static let toggle: CGFloat = 46
    static let status: CGFloat = 96
}

private struct ProviderPreferenceRow: View {
    let provider: ProviderDefinition
    let detected: Bool
    @AppStorage private var connected: Bool
    @AppStorage private var shown: Bool

    init(provider: ProviderDefinition, detected: Bool) {
        self.provider = provider
        self.detected = detected
        _connected = AppStorage(wrappedValue: true, ProviderPreferences.connectedKey(for: provider.id))
        _shown = AppStorage(wrappedValue: true, ProviderPreferences.shownKey(for: provider.id))
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                Text(provider.sourceDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Label(statusText, systemImage: statusSymbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(statusColor)
                .frame(width: LaneColumns.status, alignment: .leading)
            Toggle("Read \(provider.name) usage", isOn: $connected)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .frame(width: LaneColumns.toggle)
                .help("Let Usage HUD read \(provider.name) usage")
            Toggle("Show \(provider.name) in the panel and menu bar", isOn: $shown)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .frame(width: LaneColumns.toggle)
                .disabled(!connected)
                .help("Show \(provider.name) in the panel and the menu bar")
        }
        .accessibilityElement(children: .contain)
        .onChange(of: connected) { _, _ in ProviderPreferences.notifyChanged() }
        .onChange(of: shown) { _, _ in ProviderPreferences.notifyChanged() }
    }

    private var statusText: String {
        if !connected { return "Off" }
        return detected ? "Reading" : "No data yet"
    }

    private var statusSymbol: String {
        if !connected { return "minus.circle" }
        return detected ? "checkmark.circle.fill" : "clock"
    }

    private var statusColor: Color {
        if !connected { return .secondary }
        return detected ? .green : .orange
    }
}

// MARK: - Badge

private struct BadgeSettingsPane: View {
    @ObservedObject var state: UsageState

    // Not a grouped Form: inside one, text fields lose their borders and
    // placeholders. A card with the same fill keeps the tabs consistent.
    var body: some View {
        ScrollView {
            ReadmeBadgeSection(state: state)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
                .padding(20)
        }
    }
}

// MARK: - About

/// Agents: the onboarding prompt plus what agents can call.
struct AgentsSettingsPane: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AgentOnboardingView()
                VStack(alignment: .leading, spacing: 6) {
                    Text("What your agents get")
                        .font(.headline)
                    Text("A read-only MCP server and command line built into Usage HUD. Agents can ask which plan has room, how much of each limit is used, and when each one resets. Nothing leaves this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("Read the agent docs", destination: URL(string: "https://github.com/Thalia-Bloom/usage-hud/blob/main/AGENTS.md")!)
                        .font(.callout)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct AboutSettingsPane: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)
                .accessibilityHidden(true)
            Text(AppInfo.productName)
                .font(.system(size: 24, weight: .bold))
                .padding(.top, 10)
            Text("Version \(AppInfo.resolvedMarketingVersion) (\(BackgroundRefreshService.currentBuildNumber))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 2)
            Text("Free. Made by Thalia Bloom.")
                .font(.body)
                .padding(.top, 14)
            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.open(AppInfo.tipURL)
                } label: {
                    Label("Leave a tip", systemImage: "heart")
                }
                .buttonStyle(.borderedProminent)
                .help(AppInfo.tipURL.absoluteString)
                Button {
                    NotificationCenter.default.post(name: .usageHUDOpenSettings, object: nil, userInfo: ["pane": SettingsPane.help.rawValue])
                } label: {
                    Label("Help and support", systemImage: "questionmark.circle")
                }
                .help(AppInfo.supportURL.absoluteString)
            }
            .controlSize(.large)
            .padding(.top, 18)
            Spacer(minLength: 24)
            Text("If Usage HUD saves you an afternoon, a tip keeps it free.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
