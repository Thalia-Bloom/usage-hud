import Foundation

/// Spend and activity for agents: the same numbers as the panel's Value line
/// and the Activity window. API value is what the tokens would cost at
/// pay-per-use API prices and is never billed; "you pay" is the plan price.
enum AgentSpend {
    /// The app's saved summary when it is fresh, otherwise one scan of the
    /// session logs (the first scan of a large log folder takes seconds).
    static func current(now: Date = Date()) -> SpendSnapshotFile.Payload {
        if let saved = SpendSnapshotFile.read(now: now) { return saved }
        return SpendSnapshotFile.Payload(spend: SpendSummary.current(now: now),
                                         activity: ActivitySummary.current(now: now))
    }

    /// JSON object with ISO 8601 dates, for MCP structured content.
    static func jsonObject<T: Encodable>(_ value: T) -> [String: Any]? {
        guard let data = try? SpendJSON.encoder.encode(value) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func prettyJSON<T: Encodable>(_ value: T) -> String {
        guard let data = try? SpendJSON.encoder.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: pretty, encoding: .utf8)
        else { return "{}" }
        return text
    }

    static func spendText(_ spend: SpendSummary) -> String {
        var lines: [String] = []
        let providers = spend.providers.filter { $0.apiValue != nil || ($0.plan.monthlyUSD ?? 0) > 0 }
        if let line = SpendDisplay.valueLine(spend, visibleProviders: providers.map(\.provider)), let value = line.value {
            lines.append([("\(line.label): \(value) API value"), line.paid, line.multiple.map { "\($0) value" }]
                .compactMap { $0 }.joined(separator: " · "))
        } else {
            lines.append("No API value yet: no coding-tool session logs were found on this Mac.")
        }
        for p in providers {
            var parts: [String] = [p.name]
            if let v = SpendDisplay.laneValue(p) { parts.append(v) }
            if let name = p.plan.name, let price = SpendDisplay.planPrice(p.plan.monthlyUSD) {
                // Tier names such as "ChatGPT Pro $200" already carry the price.
                let label = name.contains("$") ? "\(name)/mo" : "\(name) \(price)"
                parts.append("plan \(label) (\(p.plan.source))")
            } else {
                parts.append("plan not set")
            }
            lines.append(parts.joined(separator: " · "))
        }
        lines.append("API value is what these tokens would cost at pay-per-use API prices; it is not billed. Plan prices are what the user pays per month.")
        return lines.joined(separator: "\n")
    }

    static func activityText(_ activity: ActivitySummary, now: Date = Date(), limit: Int = 8) -> String {
        guard !activity.sessions.isEmpty else {
            return "No coding-agent sessions in \(activity.windowLabel)."
        }
        var lines: [String] = []
        if let top = activity.sessions.max(by: { $0.usdPerHour < $1.usdPerHour }), top.usdPerHour > 0 {
            lines.append("Top burner now: \(top.toolName) · \(top.project) · \(SpendDisplay.perHour(top.usdPerHour))")
        }
        for s in activity.sessions.prefix(limit) {
            lines.append([
                s.toolName, s.project, s.model,
                "last active \(SpendDisplay.ago(s.lastActiveAt, now: now))",
                "\(SpendDisplay.tokens(s.tokens)) tokens",
                "\(SpendDisplay.money(s.apiValueUSD)) API value",
            ].joined(separator: " · "))
        }
        if activity.sessions.count > limit {
            lines.append("…and \(activity.sessions.count - limit) more in \(activity.windowLabel).")
        }
        return lines.joined(separator: "\n")
    }
}
