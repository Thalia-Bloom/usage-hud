import SwiftUI

/// Settings › Plans: what you pay for each tool, so the panel can set the
/// API value of your usage beside it. Detection fills in what this Mac
/// shows (Claude Code's sign-in, Codex's logs); anything else is a pick.
struct PlansSettingsPane: View {
    @ObservedObject var state: UsageState

    var body: some View {
        Form {
            Section {
                ForEach(PlanCatalog.providers, id: \.self) { provider in
                    PlanPickerRow(provider: provider, spend: state.spend?.provider(provider))
                }
            } header: {
                Text("What you pay")
            } footer: {
                Text("“Detect automatically” uses the plan this Mac shows. Prices are US monthly prices from each company’s pricing page, checked October 1, 2026.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Label {
                    Text("API value is what your tokens would cost at pay-per-use API prices. You are not billed for it. Usage HUD reads token counts from Claude Code, Codex and Gemini CLI logs on this Mac; prompts and messages are never read into the app.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "dollarsign.circle").foregroundStyle(.secondary)
                }
                LabeledContent("API prices") {
                    HStack(spacing: 10) {
                        Link("Anthropic", destination: URL(string: PriceVendor.anthropic.pricingURL)!)
                        Link("OpenAI", destination: URL(string: PriceVendor.openai.pricingURL)!)
                        Link("Google", destination: URL(string: PriceVendor.google.pricingURL)!)
                        Link("xAI", destination: URL(string: PriceVendor.xai.pricingURL)!)
                    }
                    .font(.callout)
                }
            } header: {
                Text("About API value")
            }
        }
        .formStyle(.grouped)
    }
}

private struct PlanPickerRow: View {
    let provider: String
    let spend: SpendSummary.Provider?
    @State private var selection: String
    @State private var customText: String
    @State private var detected: DetectedPlan?

    private static let customTag = "custom"

    init(provider: String, spend: SpendSummary.Provider?) {
        self.provider = provider
        self.spend = spend
        let choice = PlanSettings.choice(for: provider)
        switch choice {
        case .custom(let amount):
            _selection = State(initialValue: Self.customTag)
            _customText = State(initialValue: amount.rounded() == amount ? String(Int(amount)) : String(format: "%.2f", amount))
        default:
            _selection = State(initialValue: choice.stored)
            _customText = State(initialValue: "")
        }
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if selection == Self.customTag {
                    HStack(spacing: 3) {
                        Text("$").foregroundStyle(.secondary)
                        TextField("0", text: $customText)
                            .frame(width: 64)
                            .multilineTextAlignment(.trailing)
                            .onSubmit(save)
                        Text("/mo").foregroundStyle(.secondary)
                    }
                    .textFieldStyle(.roundedBorder)
                }
                Picker("Plan for \(PlanCatalog.providerName(provider))", selection: $selection) {
                    Text(autoLabel).tag("auto")
                    Divider()
                    ForEach(PlanCatalog.plans(for: provider)) { plan in
                        Text(optionLabel(plan)).tag(plan.id)
                    }
                    Divider()
                    Text("Custom amount").tag(Self.customTag)
                    Text("No plan (free or API key)").tag("none")
                }
                .labelsHidden()
                .frame(width: 250)
            }
        } label: {
            Text(PlanCatalog.providerName(provider))
            Text(subtitle)
        }
        .onAppear {
            detected = PlanDetection.detect(provider: provider, scan: TokenUsageIndex.shared.latest(), roots: .current)
        }
        .onChange(of: selection) { _, _ in save() }
        .onChange(of: customText) { _, _ in if selection == Self.customTag { save() } }
    }

    private var autoLabel: String {
        guard let detected else { return "Detect automatically" }
        return "Detect automatically (\(detected.name))"
    }

    private func optionLabel(_ plan: SubscriptionPlan) -> String {
        var label = plan.name
        if let price = SpendDisplay.planPrice(plan.monthlyUSD) { label += " · \(price)" }
        if let note = plan.note, plan.verified { label += " (\(note))" }
        if !plan.verified { label += " (price not confirmed)" }
        return label
    }

    private var subtitle: String {
        var parts: [String] = []
        if let detected {
            parts.append("This Mac shows \(detected.name), from \(detected.from).")
        } else if provider == "grok" || provider == "gemini" {
            parts.append("Not detected on this Mac; pick your plan.")
        } else {
            parts.append("Nothing detected yet.")
        }
        if let spend, let value = spend.apiValue, value.month > 0 {
            parts.append("API value, last 30 days: \(SpendDisplay.money(value.month)).")
        } else if spend?.hasLogs == false, provider != "grok" {
            parts.append("No logs on this Mac yet.")
        } else if provider == "grok" {
            parts.append("Grok token logs are not read, so only the price shows.")
        }
        return parts.joined(separator: " ")
    }

    private func save() {
        let choice: PlanChoice
        if selection == Self.customTag {
            let cleaned = customText.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard let amount = Double(cleaned), amount.isFinite, amount >= 0 else { return }
            choice = .custom(amount)
        } else {
            choice = PlanChoice(stored: selection)
        }
        guard choice != PlanSettings.choice(for: provider) else { return }
        PlanSettings.set(choice, for: provider)
    }
}
