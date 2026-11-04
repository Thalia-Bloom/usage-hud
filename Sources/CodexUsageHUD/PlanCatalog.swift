import Foundation

// ============================================================================
//  What you pay: subscription plans, their monthly prices, which one this
//  Mac is on (detected from data already on disk), and the user's choice.
// ============================================================================

struct SubscriptionPlan: Identifiable, Equatable, Sendable {
    let id: String
    /// The lane the plan pays for: claude, codex, gemini, grok.
    let provider: String
    let name: String
    /// US monthly price on monthly billing. Nil when there is no single
    /// price (per seat, or not shown on the vendor's page).
    let monthlyUSD: Double?
    let note: String?
    let source: String
    let checked: String
    /// False when the price came from somewhere other than the vendor's page.
    let verified: Bool

    init(_ id: String, _ provider: String, _ name: String, _ monthlyUSD: Double?, note: String? = nil,
         source: String, verified: Bool = true) {
        self.id = id
        self.provider = provider
        self.name = name
        self.monthlyUSD = monthlyUSD
        self.note = note
        self.source = source
        self.checked = APIPricing.checked
        self.verified = verified
    }
}

enum PlanCatalog {
    static let providers = ["claude", "codex", "gemini", "grok"]

    static let claudePricing = "https://claude.com/pricing"
    static let claudeMax = "https://support.claude.com/en/articles/11049741"
    static let codexPricing = "https://developers.openai.com/codex/pricing"
    static let googlePlans = "https://gemini.google/subscriptions"
    static let xaiPricing = "https://x.ai/pricing"

    // Prices read 2026-10-01 (US, monthly billing).
    static let plans: [SubscriptionPlan] = [
        SubscriptionPlan("claude-free", "claude", "Free", 0, source: claudePricing),
        SubscriptionPlan("claude-pro", "claude", "Pro", 20, source: claudePricing),
        SubscriptionPlan("claude-max-5x", "claude", "Max 5x", 100, source: claudeMax),
        SubscriptionPlan("claude-max-20x", "claude", "Max 20x", 200, source: claudeMax),
        SubscriptionPlan("claude-team-standard", "claude", "Team Standard", 25, note: "per seat", source: claudePricing),
        SubscriptionPlan("claude-team-premium", "claude", "Team Premium", 125, note: "per seat", source: claudePricing),
        SubscriptionPlan("claude-enterprise", "claude", "Enterprise", nil, note: "price set by contract", source: claudePricing),

        SubscriptionPlan("chatgpt-free", "codex", "ChatGPT Free", 0, source: codexPricing),
        SubscriptionPlan("chatgpt-go", "codex", "ChatGPT Go", 8, source: codexPricing),
        SubscriptionPlan("chatgpt-plus", "codex", "ChatGPT Plus", 20, source: codexPricing),
        SubscriptionPlan("chatgpt-pro-100", "codex", "ChatGPT Pro $100", 100, source: codexPricing),
        SubscriptionPlan("chatgpt-pro-200", "codex", "ChatGPT Pro $200", 200, source: codexPricing),
        SubscriptionPlan("chatgpt-pro-500", "codex", "ChatGPT Pro $500", 500, source: codexPricing),
        SubscriptionPlan("chatgpt-business", "codex", "ChatGPT Business", 25, note: "per user", source: codexPricing),
        SubscriptionPlan("chatgpt-business-premium", "codex", "ChatGPT Business Premium", nil, note: "per user", source: codexPricing),
        SubscriptionPlan("chatgpt-enterprise", "codex", "ChatGPT Enterprise", nil, note: "price set by contract", source: codexPricing),

        SubscriptionPlan("google-ai-plus", "gemini", "Google AI Plus", 4.99, source: googlePlans),
        SubscriptionPlan("google-ai-pro", "gemini", "Google AI Pro", 19.99, source: googlePlans),
        SubscriptionPlan("google-ai-ultra-5x", "gemini", "Google AI Ultra (5x)", 99.99, source: googlePlans),
        SubscriptionPlan("google-ai-ultra-20x", "gemini", "Google AI Ultra (20x)", 199.99, source: googlePlans),

        SubscriptionPlan("supergrok", "grok", "SuperGrok", 30, source: xaiPricing),
        SubscriptionPlan("supergrok-plus", "grok", "SuperGrok Plus", 100, source: xaiPricing),
        SubscriptionPlan("supergrok-heavy", "grok", "SuperGrok Heavy", 300,
                         note: "x.ai lists Heavy without a price; $300 is not confirmed", source: xaiPricing, verified: false),
    ]

    static func plans(for provider: String) -> [SubscriptionPlan] {
        plans.filter { $0.provider == provider.lowercased() }
    }

    static func plan(id: String) -> SubscriptionPlan? {
        plans.first { $0.id == id }
    }

    static func providerName(_ provider: String) -> String {
        switch provider.lowercased() {
        case "claude": return "Claude"
        case "codex": return "Codex (ChatGPT)"
        case "gemini": return "Gemini (Google AI)"
        case "grok": return "Grok (xAI)"
        default: return UsageInsights.label(for: provider)
        }
    }
}

// MARK: - The user's choice

/// Stored per lane as one string: "auto" (default), a plan id, "custom:<USD>"
/// or "none" (no plan: free tier or pay-per-use API key).
enum PlanChoice: Equatable, Sendable {
    case auto
    case plan(String)
    case custom(Double)
    case none

    init(stored: String?) {
        guard let raw = stored?.trimmingCharacters(in: .whitespaces), !raw.isEmpty, raw != "auto" else {
            self = .auto
            return
        }
        if raw == "none" { self = .none; return }
        if raw.hasPrefix("custom:"), let amount = Double(raw.dropFirst(7)), amount.isFinite, amount >= 0 {
            self = .custom(amount)
            return
        }
        self = PlanCatalog.plan(id: raw) != nil ? .plan(raw) : .auto
    }

    var stored: String {
        switch self {
        case .auto: return "auto"
        case .none: return "none"
        case .plan(let id): return id
        case .custom(let amount): return "custom:\(amount)"
        }
    }
}

enum PlanSettings {
    static let didChange = Notification.Name("UsageHUDPlanSettingsDidChange")
    /// Isolated (fixture) state dirs read plans from this file instead of
    /// the user's defaults.
    static let fixtureFilename = "plan-settings.json"

    static func key(for provider: String) -> String { "usageHUD.plan.\(provider.lowercased())" }

    static func choice(for provider: String, defaults: UserDefaults = .standard) -> PlanChoice {
        if UsagePaths.isIsolatedStateDir {
            let url = UsagePaths.stateDirectory.appendingPathComponent(fixtureFilename)
            let stored = (try? Data(contentsOf: url))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
            return PlanChoice(stored: stored?[provider.lowercased()])
        }
        return PlanChoice(stored: defaults.string(forKey: key(for: provider)))
    }

    static func set(_ choice: PlanChoice, for provider: String, defaults: UserDefaults = .standard) {
        defaults.set(choice.stored, forKey: key(for: provider))
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

// MARK: - Detection

/// A plan read from data already on this Mac.
struct DetectedPlan: Equatable, Sendable {
    var planID: String?
    var name: String
    var monthlyUSD: Double?
    /// Where it was read, in words ("Claude Code sign-in", "Codex logs").
    var from: String
}

enum PlanDetection {
    /// Claude Code's account fields. `subscriptionType` (Keychain
    /// credential) is pro / max / team / enterprise; `organizationType` in
    /// `~/.claude.json` is claude_pro / claude_max / …; the rate-limit tier
    /// tells Max 5x from Max 20x.
    static func claude(subscriptionType: String?, organizationType: String?, rateLimitTier: String?) -> DetectedPlan? {
        let tier = (rateLimitTier ?? "").lowercased()
        var kind = (subscriptionType ?? "").lowercased()
        if kind.isEmpty {
            kind = (organizationType ?? "").lowercased().replacingOccurrences(of: "claude_", with: "")
        }
        let from = "Claude Code sign-in"
        if tier.contains("max_20x") { return detected("claude-max-20x", from) }
        if tier.contains("max_5x") { return detected("claude-max-5x", from) }
        switch kind {
        case "pro": return detected("claude-pro", from)
        case "max":
            // Max without its tier: name the plan, but don't guess a price.
            return DetectedPlan(planID: nil, name: "Max", monthlyUSD: nil, from: from)
        case "team": return DetectedPlan(planID: nil, name: "Team", monthlyUSD: nil, from: from)
        case "enterprise": return detected("claude-enterprise", from)
        case "free": return detected("claude-free", from)
        default:
            if tier == "default_claude_ai" { return detected("claude-pro", from) }
            return nil
        }
    }

    /// Codex's `rate_limits.plan_type`, as named in openai/codex `PlanType`.
    static func codex(planType: String?) -> DetectedPlan? {
        let from = "Codex logs"
        switch (planType ?? "").lowercased() {
        case "free": return detected("chatgpt-free", from)
        case "go": return detected("chatgpt-go", from)
        case "plus": return detected("chatgpt-plus", from)
        case "prolite": return detected("chatgpt-pro-100", from)
        case "pro": return detected("chatgpt-pro-200", from)
        case "promax": return detected("chatgpt-pro-500", from)
        case "team", "business", "self_serve_business_usage_based": return detected("chatgpt-business", from)
        case "self_serve_business_prolite": return detected("chatgpt-business-premium", from)
        case "enterprise": return detected("chatgpt-enterprise", from)
        default: return nil
        }
    }

    private static func detected(_ id: String, _ from: String) -> DetectedPlan? {
        guard let plan = PlanCatalog.plan(id: id) else { return nil }
        return DetectedPlan(planID: plan.id, name: plan.name, monthlyUSD: plan.monthlyUSD, from: from)
    }

    /// Reads only the plan fields of `oauthAccount` in Claude Code's
    /// `~/.claude.json`; nothing else in that file is kept.
    static func claudeAccountFields(configURL: URL?) -> (organizationType: String?, rateLimitTier: String?)? {
        guard let configURL else { return nil }
        return claudeConfigCache.value(for: configURL) { url in
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let account = object["oauthAccount"] as? [String: Any] else { return nil }
            let tier = (account["userRateLimitTier"] as? String) ?? (account["organizationRateLimitTier"] as? String)
            return (account["organizationType"] as? String, tier)
        }
    }

    private static let claudeConfigCache = FileSignatureCache<(organizationType: String?, rateLimitTier: String?)?>(limit: 4)

    /// Plan fields the in-app Claude reader saved from the Keychain
    /// credential it already reads for the usage endpoint (never the token).
    static func claudeCredentialFields(stateDirectory: URL = UsagePaths.stateDirectory) -> (subscriptionType: String?, rateLimitTier: String?)? {
        let url = stateDirectory.appendingPathComponent(UsagePaths.claudeNativeUsageFilename)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plan = object["plan"] as? [String: Any] else { return nil }
        return (plan["subscriptionType"] as? String, plan["rateLimitTier"] as? String)
    }

    /// Best detection for one lane from what is on disk.
    static func detect(provider: String, scan: TokenScan?, roots: TokenLogRoots) -> DetectedPlan? {
        switch provider.lowercased() {
        case "claude":
            let credential = roots.isEmpty ? nil : claudeCredentialFields()
            let config = claudeAccountFields(configURL: roots.claudeConfig)
            return claude(
                subscriptionType: credential?.subscriptionType,
                organizationType: config?.organizationType,
                rateLimitTier: credential?.rateLimitTier ?? config?.rateLimitTier
            )
        case "codex":
            let newest = scan?.files
                .filter { $0.tool == .codex && $0.planType != nil }
                .max { ($0.planTypeAt ?? .distantPast) < ($1.planTypeAt ?? .distantPast) }
            return codex(planType: newest?.planType)
        default:
            return nil
        }
    }
}

// MARK: - Resolved plan

struct ResolvedPlan: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case detected, user, unset }

    var name: String?
    var monthlyUSD: Double?
    var source: Source
    var planID: String?
    /// Where a detected plan was read, or the plan's caveat.
    var note: String?

    static let unset = ResolvedPlan(name: nil, monthlyUSD: nil, source: .unset)

    var isSet: Bool { source != .unset }

    static func resolve(choice: PlanChoice, detected: DetectedPlan?) -> ResolvedPlan {
        switch choice {
        case .auto:
            guard let detected else { return .unset }
            return ResolvedPlan(name: detected.name, monthlyUSD: detected.monthlyUSD, source: .detected,
                                planID: detected.planID, note: "from \(detected.from)")
        case .none:
            return ResolvedPlan(name: "No plan", monthlyUSD: 0, source: .user)
        case .custom(let amount):
            return ResolvedPlan(name: "Custom", monthlyUSD: amount, source: .user)
        case .plan(let id):
            guard let plan = PlanCatalog.plan(id: id) else { return .unset }
            return ResolvedPlan(name: plan.name, monthlyUSD: plan.monthlyUSD, source: .user, planID: plan.id, note: plan.note)
        }
    }
}
