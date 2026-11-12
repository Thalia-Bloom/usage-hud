import Foundation

/// Words and numbers for the Value line, the lane cards and the Activity
/// window. Pure, so the copy is tested without rendering.
enum SpendDisplay {
    static let notBilled = "not billed"
    static let apiValueHelp = "API value is what these tokens would cost at pay-per-use API prices (checked Oct 1, 2026). Your plan is a flat subscription, so this is not money you spent."

    static func money(_ usd: Double) -> String {
        guard usd.isFinite else { return "--" }
        let v = max(0, usd)
        if v == 0 { return "$0" }
        if v < 0.01 { return "<$0.01" }
        if v < 10 { return String(format: "$%.2f", v) }
        if v < 100_000 {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.maximumFractionDigits = 0
            f.locale = Locale(identifier: "en_US")
            return "$" + (f.string(from: NSNumber(value: v.rounded())) ?? "\(Int(v.rounded()))")
        }
        return String(format: "$%.0fK", v / 1000)
    }

    static func perHour(_ usd: Double) -> String {
        guard usd.isFinite, usd > 0 else { return "$0/h" }
        if usd < 10 { return String(format: "$%.2f/h", usd) }
        return "\(money(usd))/h"
    }

    static func multiple(_ x: Double) -> String {
        guard x.isFinite, x > 0 else { return "0×" }
        if x >= 10 { return "\(Int(x.rounded()))×" }
        return String(format: "%.1f×", x)
    }

    static func tokens(_ n: Int) -> String {
        let v = Double(max(0, n))
        if v >= 1_000_000_000 { return String(format: "%.1fB", v / 1_000_000_000) }
        if v >= 1_000_000 { return String(format: v >= 100_000_000 ? "%.0fM" : "%.1fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: v >= 100_000 ? "%.0fK" : "%.1fK", v / 1_000) }
        return "\(Int(v))"
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3600)h ago" }
        return "\(s / 86_400)d ago"
    }

    static func planPrice(_ usd: Double?) -> String? {
        guard let usd else { return nil }
        if usd == 0 { return "$0/mo" }
        if usd.rounded() == usd { return "$\(Int(usd))/mo" }
        return String(format: "$%.2f/mo", usd)
    }

    // MARK: Panel Value line

    struct ValueLine: Equatable {
        var label = "This week"
        /// "$412", or nil while the logs are being read.
        var value: String?
        /// "you pay $46 of $200/mo"
        var paid: String?
        var multiple: String?
        /// "$92": the plans' cost this week, and the multiple as a number.
        var paidWeek: String?
        var multipleValue: Double?
        var valueUSD: Double?
        var paidWeekUSD: Double?
        /// A lane with API value has no plan set.
        var showSetPlan = false
        var reading = false
        var help = ""

        /// The panel's weekly win shows only as a win: never "$0 of work",
        /// never less work than the plans cost. Still reading counts as a win.
        var isWin: Bool {
            guard let v = valueUSD else { return value == nil }
            return v > 0 && v >= (paidWeekUSD ?? 0)
        }
    }

    /// One line for the lanes on show. Nil when none of them has logs and
    /// none has a plan (nothing honest to say).
    static func valueLine(_ spend: SpendSummary?, visibleProviders: [String]) -> ValueLine? {
        let visible = Set(visibleProviders.map { $0.lowercased() })
        let relevant = PlanCatalog.providers.filter { visible.contains($0) }
        guard !relevant.isEmpty else { return nil }
        guard let spend else {
            return ValueLine(value: nil, reading: true, help: "Reading the coding tools' session logs on this Mac. The first read can take a few seconds.")
        }
        let lanes = relevant.compactMap { spend.provider($0) }
        let withValue = lanes.filter { $0.apiValue != nil }
        let priced = lanes.filter { ($0.plan.monthlyUSD ?? 0) > 0 }
        guard !withValue.isEmpty || !priced.isEmpty else { return nil }

        let value = withValue.reduce(0) { $0 + ($1.apiValue?.week ?? 0) }
        let estimated = withValue.contains { $0.apiValue?.estimated == true }
        var line = ValueLine(value: money(value))
        line.valueUSD = value

        let paired = priced.filter { $0.apiValue != nil }
        let monthly = priced.reduce(0) { $0 + ($1.plan.monthlyUSD ?? 0) }
        if monthly > 0 {
            let week = SpendPeriods.prorated(monthlyUSD: monthly, days: 7)
            line.paid = "you pay \(money(week)) of \(planPrice(monthly) ?? "")"
            line.paidWeek = money(week)
            line.paidWeekUSD = week
            let pairedMonthly = paired.reduce(0) { $0 + ($1.plan.monthlyUSD ?? 0) }
            if pairedMonthly > 0 {
                let pairedValue = paired.reduce(0) { $0 + ($1.apiValue?.week ?? 0) }
                let x = pairedValue / SpendPeriods.prorated(monthlyUSD: pairedMonthly, days: 7)
                if x > 0 { line.multiple = multiple(x); line.multipleValue = x }
            }
        }
        line.showSetPlan = withValue.contains { $0.plan.source == ResolvedPlan.Source.unset.rawValue && ($0.apiValue?.week ?? 0) > 0 }

        var help: [String] = []
        let names = withValue.map { lane in UsageInsights.label(for: lane.provider) }
        help.append("API value: what this week's \(listText(names)) tokens would cost at pay-per-use API prices. You are not billed for it.\(estimated ? " Some models are priced from their family's current model (estimated)." : "")")
        if monthly > 0 {
            let plans = priced.map { "\($0.plan.name ?? UsageInsights.label(for: $0.provider)) \(planPrice($0.plan.monthlyUSD) ?? "")" }
            help.append("You pay: \(listText(plans)) a month, spread over the last 7 days.")
            if let m = line.multiple { help.append("\(m) = API value of the lanes with a plan ÷ what those plans cost this week.") }
        }
        if line.showSetPlan { help.append("Set your plan in Settings › Plans to see what you pay.") }
        help.append("Week = the last 7 days, including today.")
        line.help = help.joined(separator: "\n")
        return line
    }

    // MARK: Lane cards

    /// "$163 today · $2,689 week · $5,500 30 days"
    static func laneValue(_ p: SpendSummary.Provider) -> String? {
        guard let v = p.apiValue else { return nil }
        if v.month == 0 { return "$0 in the last 30 days" }
        return "\(money(v.today)) today · \(money(v.week)) week · \(money(v.month)) 30 days"
    }

    static func laneTokens(_ p: SpendSummary.Provider) -> String? {
        guard let t = p.tokens, t.month > 0 else { return nil }
        return "\(tokens(t.today)) today · \(tokens(t.week)) week · cache included"
    }

    struct PlanText: Equatable {
        var text: String
        var detail: String?
        var isSet: Bool
    }

    /// "Max 20x · $200/mo · 28× in 30 days", plus where it came from.
    static func lanePlan(_ p: SpendSummary.Provider) -> PlanText {
        guard p.plan.source != ResolvedPlan.Source.unset.rawValue, let name = p.plan.name else {
            return PlanText(text: "Not set", detail: nil, isSet: false)
        }
        var parts = [name]
        // Tier names such as "ChatGPT Pro $200" already carry the price.
        if name.contains("$") {
            parts = ["\(name)/mo"]
        } else if let price = planPrice(p.plan.monthlyUSD) {
            parts.append(price)
        } else {
            parts.append("price not set")
        }
        if let x = p.valueMultiple, x > 0 { parts.append("\(multiple(x)) in 30 days") }
        let detail: String = p.plan.source == ResolvedPlan.Source.detected.rawValue
            ? "detected"
            : "set by you"
        return PlanText(text: parts.joined(separator: " · "), detail: detail, isSet: true)
    }

    static func laneHelp(_ p: SpendSummary.Provider) -> String {
        var lines = [apiValueHelp, "Today since midnight; week = the last 7 days; 30 days including today."]
        if !p.estimatedModels.isEmpty {
            lines.append("Estimated: \(p.estimatedModels.joined(separator: ", ")) \(p.estimatedModels.count == 1 ? "is" : "are") not on the vendor's price list, so \(p.estimatedModels.count == 1 ? "it is" : "they are") priced like the closest listed model.")
        }
        if p.provider == "gemini" {
            lines.append("Counted from Gemini CLI chats. Antigravity keeps its conversations in a format with no published token counts, so its use is not included.")
        }
        if let note = p.plan.note { lines.append("Plan \(note).") }
        return lines.joined(separator: "\n")
    }

    private static func listText(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }
}
