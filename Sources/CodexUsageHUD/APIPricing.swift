import Foundation

// ============================================================================
//  Pay-per-use API prices, compiled into the app.
//
//  "API value" is what the tokens a subscription used would have cost at
//  these prices. Nobody is billed for it; it is a yardstick for what a flat
//  plan is worth. Every row names the official page it was read from and
//  the day it was checked. A model that is not in the table is priced from
//  its family's current model and flagged as estimated.
// ============================================================================

/// USD per million tokens.
struct ModelRate: Equatable, Sendable {
    var input: Double
    var cacheRead: Double
    /// Short (5-minute) cache writes; vendors with one write rate use this.
    var cacheWrite5m: Double
    var cacheWrite1h: Double
    var output: Double

    init(input: Double, cacheRead: Double, cacheWrite5m: Double, cacheWrite1h: Double? = nil, output: Double) {
        self.input = input
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h ?? cacheWrite5m
        self.output = output
    }

    /// Vendors without a cache-write fee bill written tokens as input.
    static func noWriteFee(input: Double, cacheRead: Double, output: Double) -> ModelRate {
        ModelRate(input: input, cacheRead: cacheRead, cacheWrite5m: input, output: output)
    }

    func scaled(_ factor: Double) -> ModelRate {
        ModelRate(input: input * factor, cacheRead: cacheRead * factor, cacheWrite5m: cacheWrite5m * factor,
                  cacheWrite1h: cacheWrite1h * factor, output: output * factor)
    }

    func cost(_ c: TokenCounts) -> Double {
        (Double(c.input) * input
            + Double(c.cacheRead) * cacheRead
            + Double(c.cacheWrite5m) * cacheWrite5m
            + Double(c.cacheWrite1h) * cacheWrite1h
            + Double(c.output) * output) / 1_000_000
    }
}

enum PriceVendor: String, Sendable {
    case anthropic, openai, google, xai, local

    var pricingURL: String {
        switch self {
        case .anthropic: return "https://platform.claude.com/docs/en/about-claude/pricing"
        case .openai: return "https://developers.openai.com/api/docs/pricing"
        case .google: return "https://ai.google.dev/gemini-api/docs/pricing"
        case .xai: return "https://docs.x.ai/developers/pricing"
        case .local: return ""
        }
    }
}

struct ModelPrice: Sendable {
    let ids: [String]
    let vendor: PriceVendor
    let rate: ModelRate
    /// Prompts above `threshold` tokens bill every token at `rate`.
    let longContext: (threshold: Int, rate: ModelRate)?
    let note: String?
    let source: String
    let checked: String

    init(_ ids: [String], _ vendor: PriceVendor, _ rate: ModelRate,
         long: (Int, ModelRate)? = nil, note: String? = nil, checked: String = APIPricing.checked) {
        self.ids = ids
        self.vendor = vendor
        self.rate = rate
        self.longContext = long.map { (threshold: $0.0, rate: $0.1) }
        self.note = note
        self.source = vendor.pricingURL
        self.checked = checked
    }
}

enum APIPricing {
    static let checked = "2026-10-01"

    private static func anthropic(_ input: Double, _ read: Double, _ w5: Double, _ w1: Double, _ output: Double) -> ModelRate {
        ModelRate(input: input, cacheRead: read, cacheWrite5m: w5, cacheWrite1h: w1, output: output)
    }

    private static func openai(_ input: Double, _ read: Double, _ write: Double?, _ output: Double) -> ModelRate {
        ModelRate(input: input, cacheRead: read, cacheWrite5m: write ?? input, output: output)
    }

    // Read from each vendor's official pricing page on 2026-10-01
    // (standard tier, USD per 1M tokens).
    static let table: [ModelPrice] = [
        // Anthropic: input, cache read, 5-minute write, 1-hour write, output.
        ModelPrice(["claude-fable-5-1", "claude-mythos-5-1"], .anthropic, anthropic(10, 0.25, 12.50, 20, 50)),
        ModelPrice(["claude-fable-5", "claude-mythos-5"], .anthropic, anthropic(10, 1.00, 12.50, 20, 50)),
        ModelPrice(["claude-opus-5-5"], .anthropic, anthropic(4, 0.20, 5, 8, 20)),
        ModelPrice(["claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5"],
                   .anthropic, anthropic(5, 0.50, 6.25, 10, 25)),
        ModelPrice(["claude-opus-4-1", "claude-opus-4"], .anthropic, anthropic(15, 1.50, 18.75, 30, 75),
                   note: "retired on the Claude API"),
        ModelPrice(["claude-sonnet-5-5", "claude-sonnet-5"], .anthropic, anthropic(2, 0.20, 2.50, 4, 10)),
        ModelPrice(["claude-sonnet-4-6", "claude-sonnet-4-5", "claude-sonnet-4"], .anthropic, anthropic(3, 0.30, 3.75, 6, 15)),
        ModelPrice(["claude-haiku-4-5"], .anthropic, anthropic(1, 0.10, 1.25, 2, 5)),
        ModelPrice(["claude-3-5-haiku", "claude-haiku-3-5"], .anthropic, anthropic(0.80, 0.08, 1, 1.60, 4),
                   note: "retired on the Claude API"),

        // OpenAI: input, cached input, cache write (1.25x input on GPT-5.6
        // and later; none before), output; long tier above 272K prompt tokens.
        ModelPrice(["gpt-6-astra"], .openai, openai(10, 1.00, 12.50, 50), long: (272_000, openai(20, 2.00, 25, 75))),
        ModelPrice(["gpt-6.1-sol"], .openai, openai(2, 0.10, 2.50, 10), long: (272_000, openai(4, 0.20, 5, 15))),
        ModelPrice(["gpt-6-sol"], .openai, openai(2, 0.20, 2.50, 10), long: (272_000, openai(4, 0.40, 5, 15))),
        ModelPrice(["gpt-6-luna"], .openai, openai(0.10, 0.01, 0.125, 0.50), long: (272_000, openai(0.20, 0.02, 0.25, 0.75))),
        ModelPrice(["gpt-5.6-sol", "gpt-daybreak-blue-latest"], .openai, openai(4, 0.40, 5, 20),
                   long: (272_000, openai(8, 0.80, 10, 30)),
                   note: "promotional price through at least 2026-11-21; gpt-daybreak-blue-latest bills as gpt-5.6-sol"),
        ModelPrice(["gpt-5.6-terra"], .openai, openai(2, 0.20, 2.50, 12), long: (272_000, openai(4, 0.40, 5, 18))),
        ModelPrice(["gpt-5.6-luna"], .openai, openai(0.20, 0.02, 0.25, 1.20), long: (272_000, openai(0.40, 0.04, 0.50, 1.80))),
        ModelPrice(["gpt-5.5"], .openai, openai(5, 0.50, nil, 30), long: (272_000, openai(10, 1.00, nil, 45))),
        ModelPrice(["gpt-5.4"], .openai, openai(2.50, 0.25, nil, 15), long: (272_000, openai(5, 0.50, nil, 22.50))),
        ModelPrice(["gpt-5.3-codex"], .openai, openai(1.75, 0.175, nil, 14)),

        // Google Gemini API: input, cached, output; no cache-write fee
        // (cache storage per hour is not counted); long tier above 200K.
        ModelPrice(["gemini-3.1-pro-preview", "gemini-3.1-pro-preview-customtools", "gemini-3.1-pro"], .google,
                   .noWriteFee(input: 2.00, cacheRead: 0.20, output: 12.00),
                   long: (200_000, .noWriteFee(input: 4.00, cacheRead: 0.40, output: 18.00))),
        ModelPrice(["gemini-3-flash-preview"], .google, .noWriteFee(input: 0.50, cacheRead: 0.05, output: 3.00)),
        ModelPrice(["gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.6-flash"], .google,
                   .noWriteFee(input: 0.75, cacheRead: 0.075, output: 3.75),
                   note: "doubles to 1.50 / 0.15 / 7.50 on 2027-01-01"),
        ModelPrice(["gemini-3.5-flash"], .google, .noWriteFee(input: 1.50, cacheRead: 0.15, output: 9.00)),
        ModelPrice(["gemini-3.5-flash-lite"], .google, .noWriteFee(input: 0.30, cacheRead: 0.03, output: 2.50)),
        ModelPrice(["gemini-3.1-flash-lite"], .google, .noWriteFee(input: 0.25, cacheRead: 0.025, output: 1.50)),
        ModelPrice(["gemini-2.5-pro"], .google, .noWriteFee(input: 1.25, cacheRead: 0.125, output: 10.00),
                   long: (200_000, .noWriteFee(input: 2.50, cacheRead: 0.25, output: 15.00))),
        ModelPrice(["gemini-2.5-flash"], .google, .noWriteFee(input: 0.30, cacheRead: 0.03, output: 2.50)),
        ModelPrice(["gemini-2.5-flash-lite"], .google, .noWriteFee(input: 0.10, cacheRead: 0.01, output: 0.40)),

        // xAI: input, cached, output; long tier at 200K prompt tokens.
        ModelPrice(["grok-4.7", "grok-4.6"], .xai, .noWriteFee(input: 2.00, cacheRead: 0.50, output: 6.00),
                   long: (199_999, .noWriteFee(input: 4.00, cacheRead: 1.00, output: 12.00))),
        ModelPrice(["grok-4.5"], .xai, .noWriteFee(input: 2.00, cacheRead: 0.30, output: 6.00),
                   long: (199_999, .noWriteFee(input: 4.00, cacheRead: 0.60, output: 12.00))),
        ModelPrice(["grok-4.3", "grok-4.20-0309-reasoning", "grok-4.20-0309-non-reasoning", "grok-4.20-multi-agent-0309"], .xai,
                   .noWriteFee(input: 1.25, cacheRead: 0.20, output: 2.50),
                   long: (199_999, .noWriteFee(input: 2.50, cacheRead: 0.40, output: 5.00))),
        ModelPrice(["grok-build-0.1"], .xai, .noWriteFee(input: 1.00, cacheRead: 0.20, output: 2.00),
                   long: (199_999, .noWriteFee(input: 2.00, cacheRead: 0.40, output: 4.00))),
    ]

    /// Ids that are billed as another listed model. `estimated` is true when
    /// the vendor does not list the id itself (retired, or Codex-only).
    static let aliases: [String: (id: String, estimated: Bool)] = [
        // Codex's automatic approval reviewer; with an API key Codex runs
        // gpt-5.6-luna for the same job.
        "codex-auto-review": ("gpt-5.6-luna", true),
        // Retired Codex models: billed at their named replacements.
        "gpt-5-codex": ("gpt-5.6-sol", true),
        "gpt-5.1-codex": ("gpt-5.6-sol", true),
        "gpt-5.1-codex-max": ("gpt-5.6-sol", true),
        "gpt-5.1-codex-mini": ("gpt-5.6-terra", true),
        "gpt-5.2-codex": ("gpt-5.6-sol", true),
        "codex-mini-latest": ("gpt-5.6-terra", true),
        // Retired Gemini preview, replaced by 3.1 Pro Preview.
        "gemini-3-pro-preview": ("gemini-3.1-pro-preview", true),
        // Retired xAI slugs redirect and bill as their targets.
        "grok-code-fast-1": ("grok-build-0.1", true),
        "grok-4-0709": ("grok-4.3", true),
        "grok-3": ("grok-4.3", true),
    ]

    struct Quote: Equatable, Sendable {
        var rate: ModelRate
        /// Which listed model the price came from.
        var pricedAs: String
        /// Not the model's own listed price (family default, alias, fast mode).
        var estimated: Bool
        /// A model running on this Mac: no API price.
        var local: Bool
    }

    private static let byID: [String: ModelPrice] = {
        var map: [String: ModelPrice] = [:]
        for row in table { for id in row.ids { map[id] = row } }
        return map
    }()

    private static let quoteCache = QuoteCache()

    /// The price for one request of `model`. `longContext` selects the
    /// vendor's long-prompt tier where it has one.
    static func quote(model: String, longContext: Bool = false, fast: Bool = false, tool: AgentTool? = nil) -> Quote {
        let cacheKey = "\(model)|\(longContext)|\(fast)|\(tool?.rawValue ?? "")"
        if let hit = quoteCache.get(cacheKey) { return hit }
        var quote = uncachedQuote(model: model, longContext: longContext, tool: tool)
        if fast, !quote.local {
            // Fast mode is a premium tier at about twice the standard rate.
            quote.rate = quote.rate.scaled(2)
            quote.estimated = true
        }
        quoteCache.set(cacheKey, quote)
        return quote
    }

    static func cost(_ counts: TokenCounts, model: String, longContext: Bool = false, fast: Bool = false, tool: AgentTool? = nil) -> (usd: Double, estimated: Bool) {
        let q = quote(model: model, longContext: longContext, fast: fast, tool: tool)
        return (q.rate.cost(counts), q.estimated)
    }

    static func price(id: String) -> ModelPrice? { byID[id] }

    /// True when a prompt of `promptTokens` crosses this model's
    /// long-context tier. Decided per request, at read time.
    static func isLongContext(model: String, promptTokens: Int) -> Bool {
        guard let row = resolve(normalize(model))?.row, let long = row.longContext else { return false }
        return promptTokens > long.threshold
    }

    static func normalize(_ model: String) -> String {
        var id = model.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }   // "claude-opus-5-5[1m]"
        if let at = id.firstIndex(of: "@") { id = String(id[..<at]) }             // vendor version tags
        for prefix in ["anthropic/", "openai/", "google/", "xai/", "models/"] where id.hasPrefix(prefix) {
            id.removeFirst(prefix.count)
        }
        // Dated snapshots: "-20251001" (Anthropic) or "-2026-03-05" (OpenAI).
        if let range = id.range(of: #"-\d{8}$"#, options: .regularExpression) { id.removeSubrange(range) }
        if let range = id.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) { id.removeSubrange(range) }
        return id
    }

    private static func resolve(_ id: String) -> (row: ModelPrice, estimated: Bool)? {
        if let row = byID[id] { return (row, false) }
        if let alias = aliases[id], let row = byID[alias.id] { return (row, alias.estimated) }
        if id.hasPrefix("grok-4-fast") || id.hasPrefix("grok-4-1-fast"), let row = byID["grok-4.3"] { return (row, true) }
        return nil
    }

    static func isLocalModel(_ id: String) -> Bool {
        if id.contains(":") { return true }   // Ollama tags: "qwen3:4b"
        let local = ["qwen", "llama", "gemma", "mistral", "mixtral", "phi", "deepseek", "gpt-oss", "smollm", "granite", "olmo"]
        return local.contains { id.hasPrefix($0) }
    }

    /// The current model of a family, for ids the table does not list.
    static func familyDefault(_ id: String, tool: AgentTool?) -> String {
        if id.contains("fable") || id.contains("mythos") { return "claude-fable-5-1" }
        if id.contains("opus") { return "claude-opus-5-5" }
        if id.contains("sonnet") { return "claude-sonnet-5" }
        if id.contains("haiku") { return "claude-haiku-4-5" }
        if id.hasPrefix("claude") { return "claude-sonnet-5" }
        if id.hasPrefix("gemini") {
            if id.contains("flash-lite") { return "gemini-3.5-flash-lite" }
            if id.contains("flash") { return "gemini-3.5-flash" }
            return "gemini-3.1-pro-preview"
        }
        if id.hasPrefix("grok") {
            return id.contains("build") || id.contains("code") ? "grok-build-0.1" : "grok-4.7"
        }
        if id.contains("astra") { return "gpt-6-astra" }
        if id.contains("luna") { return id.hasPrefix("gpt-5") ? "gpt-5.6-luna" : "gpt-6-luna" }
        if id.contains("terra") { return "gpt-5.6-terra" }
        if id.contains("sol") { return id.hasPrefix("gpt-5") ? "gpt-5.6-sol" : "gpt-6-sol" }
        if id.hasPrefix("gpt") || id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4") || id.contains("codex") {
            return "gpt-6-sol"
        }
        switch tool {
        case .claude: return "claude-sonnet-5"
        case .gemini: return "gemini-3.1-pro-preview"
        case .codex, nil: return "gpt-6-sol"
        }
    }

    private static func uncachedQuote(model: String, longContext: Bool, tool: AgentTool?) -> Quote {
        let id = normalize(model)
        if isLocalModel(id) {
            return Quote(rate: ModelRate(input: 0, cacheRead: 0, cacheWrite5m: 0, output: 0), pricedAs: id, estimated: false, local: true)
        }
        let resolved = resolve(id) ?? byID[familyDefault(id, tool: tool)].map { ($0, true) }
        guard let (row, estimated) = resolved else {
            // Unreachable while the family defaults are in the table.
            return Quote(rate: ModelRate(input: 3, cacheRead: 0.3, cacheWrite5m: 3.75, output: 15), pricedAs: "default", estimated: true, local: false)
        }
        let rate = longContext ? (row.longContext?.rate ?? row.rate) : row.rate
        return Quote(rate: rate, pricedAs: row.ids[0], estimated: estimated, local: false)
    }

    private final class QuoteCache: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: Quote] = [:]
        func get(_ key: String) -> Quote? { lock.lock(); defer { lock.unlock() }; return map[key] }
        func set(_ key: String, _ value: Quote) {
            lock.lock()
            if map.count > 512 { map.removeAll() }
            map[key] = value
            lock.unlock()
        }
    }
}
