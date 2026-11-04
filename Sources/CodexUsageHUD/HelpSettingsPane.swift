import SwiftUI

/// A single destination from the panel, menu and setup results. Recovery,
/// updates and contacting support should not require knowing app internals.
struct HelpSettingsPane: View {
    @ObservedObject var state: UsageState
    @ObservedObject var jobs: BackgroundJobsModel

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button("Run health check") { jobs.run(.diagnostics, state: state) }
                        .buttonStyle(.borderedProminent)
                        .disabled(jobs.busy)
                        .accessibilityIdentifier("support.healthCheck")
                } label: {
                    Text("Missing or old readings?")
                    Text("Find out what needs attention and what to do next.")
                }
                if jobs.busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(jobs.activity).foregroundStyle(.secondary)
                    }
                } else if let result = jobs.result {
                    ResultView(result: result, showDetails: $jobs.showDetails)
                }
                if jobs.result == nil {
                    Link("Setup and troubleshooting guide", destination: AppInfo.supportURL)
                    Text("A rate limit means the provider has asked us to wait. Keep Usage HUD open for automatic retries; repeating setup won’t shorten the wait.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } header: { Text("Get back on track") }

            Section {
                LabeledContent {
                    Button("Check for Updates…") {
                        NotificationCenter.default.post(name: .usageHUDCheckForUpdates, object: nil)
                    }
                    .accessibilityIdentifier("support.checkForUpdates")
                } label: {
                    Text("Usage HUD \(AppInfo.resolvedMarketingVersion)")
                    Text("Checks for the latest stable release.")
                }
                Text("If you’re up to date, there is no newer stable update available. Preview releases are separate.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("Updates") }

            Section {
                LabeledContent {
                    Link("Email support…", destination: SupportReport.emailURL())
                } label: {
                    Text("Still stuck? Tell us what happened.")
                    Text("No GitHub account needed. Keep follow-ups in the same email thread.")
                }
                Text("For a useful report, run the health check above, choose Preview support report, then Email this report or Copy report. You review it before sharing; nothing is sent automatically.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("Contact us") }
        }
        .formStyle(.grouped)
    }
}
