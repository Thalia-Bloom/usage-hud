import Foundation
import XCTest
@testable import CodexUsageHUD

/// Fixture snapshots on a fixed clock for the agent-interface tests.
enum AgentFixtures {
    static let now = ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z")!

    static func iso(_ offset: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(offset))
    }

    static let hour: TimeInterval = 3600
    static let day: TimeInterval = 86_400

    /// A lane snapshot. `weekResetIn` / `sessionResetIn` are seconds from `now`.
    static func snapshot(
        _ provider: String,
        week: Double? = nil,
        weekResetIn: TimeInterval? = 3.5 * day,
        weekLabel: String? = nil,
        weekState: String? = nil,
        session: Double? = nil,
        sessionResetIn: TimeInterval? = 2 * hour,
        fable: Double? = nil,
        readingAge: TimeInterval = 60,
        confidence: String = "official",
        sourceKind: String = "official_api",
        sourcePath: String? = nil,
        source: String? = nil
    ) -> UsageSnapshot {
        let read = iso(-readingAge)
        let weekWindow = (week != nil || weekState != nil) ? UsageSnapshot.WindowMetric(
            label: weekLabel ?? "\(provider) weekly",
            usedPct: week,
            resetAt: weekResetIn.map { iso($0) },
            id: "week",
            eventAt: read,
            state: weekState
        ) : nil
        let sessionWindow = session.map {
            UsageSnapshot.WindowMetric(label: "Current session", usedPct: $0, resetAt: sessionResetIn.map { iso($0) },
                                       id: "5h", eventAt: read)
        }
        let fableWindow = fable.map {
            UsageSnapshot.WindowMetric(label: "Fable week", usedPct: $0, resetAt: weekResetIn.map { iso($0) },
                                       id: "fable-week", eventAt: read)
        }
        return UsageSnapshot(
            provider: provider,
            displayName: provider.capitalized,
            source: source,
            sourceKind: sourceKind,
            confidence: confidence,
            updatedAt: read,
            capturedAt: read,
            eventAt: read,
            currentSession: sessionWindow,
            week: weekWindow,
            weekFable: fableWindow,
            sourcePath: sourcePath
        )
    }

    static func summary(_ snapshots: [UsageSnapshot], visible: [String]? = nil) -> AgentSummary {
        AgentSummary.build(
            snapshots: snapshots,
            visibleProviders: visible ?? snapshots.map(\.provider),
            appVersion: "9.9.9",
            now: now
        )
    }

    /// A realistic multi-lane fleet: Claude fresh and on pace, Codex almost
    /// spent, Gemini daily, Grok with room, Local.
    static var fleet: [UsageSnapshot] {
        [
            snapshot("codex", week: 93, weekResetIn: 1.8 * day),
            snapshot("claude", week: 40, weekResetIn: 3.5 * day, session: 12, sessionResetIn: 3 * hour, fable: 5,
                     confidence: "high", sourceKind: "statusline_event", sourcePath: "/Users/someone/.claude/.credentials.json"),
            snapshot("gemini", week: 20, weekResetIn: 10 * hour, weekLabel: "Gemini quota"),
            snapshot("grok", week: 8, weekResetIn: 6 * day),
            UsageSnapshot(provider: "local", displayName: "Local", sourceKind: "local_runtime_log", confidence: "high",
                          updatedAt: iso(-60), capturedAt: iso(-60)),
        ]
    }

    static func json<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }
}

/// A small JSON Schema (2020-12 subset) checker: type, enum, const, required,
/// properties, additionalProperties: false, items, anyOf, minimum. Enough to
/// hold the binary's output to the schema it publishes.
enum MiniSchemaValidator {
    static func errors(_ value: Any, schema: [String: Any], path: String = "$") -> [String] {
        var out: [String] = []
        if let anyOf = schema["anyOf"] as? [[String: Any]] {
            if !anyOf.contains(where: { errors(value, schema: $0, path: path).isEmpty }) {
                out.append("\(path): matches no anyOf branch")
            }
            return out
        }
        if let type = schema["type"] {
            let types = (type as? [String]) ?? [(type as? String) ?? ""]
            if !types.contains(where: { matches(value, type: $0) }) {
                out.append("\(path): expected \(types.joined(separator: "|")), got \(describe(value))")
                return out
            }
        }
        if let allowed = schema["enum"] as? [Any], !allowed.contains(where: { equal($0, value) }) {
            out.append("\(path): \(describe(value)) not in enum")
        }
        if let constant = schema["const"], !equal(constant, value) {
            out.append("\(path): \(describe(value)) != const")
        }
        if let minimum = (schema["minimum"] as? NSNumber)?.doubleValue, let number = value as? NSNumber, !isBool(value), number.doubleValue < minimum {
            out.append("\(path): \(number) < minimum \(minimum)")
        }
        if let object = value as? [String: Any] {
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for key in schema["required"] as? [String] ?? [] where object[key] == nil {
                out.append("\(path): missing required \(key)")
            }
            if (schema["additionalProperties"] as? Bool) == false {
                for key in object.keys where properties[key] == nil {
                    out.append("\(path): unexpected property \(key)")
                }
            }
            for (key, sub) in properties {
                if let child = object[key], let subSchema = sub as? [String: Any] {
                    out += errors(child, schema: subSchema, path: "\(path).\(key)")
                }
            }
        }
        if let array = value as? [Any], let items = schema["items"] as? [String: Any] {
            for (i, item) in array.enumerated() {
                out += errors(item, schema: items, path: "\(path)[\(i)]")
            }
        }
        return out
    }

    private static func isBool(_ value: Any) -> Bool {
        guard let n = value as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    private static func matches(_ value: Any, type: String) -> Bool {
        switch type {
        case "null": return value is NSNull
        case "boolean": return isBool(value)
        case "number": return value is NSNumber && !isBool(value)
        case "integer":
            guard let n = value as? NSNumber, !isBool(value) else { return false }
            return n.doubleValue.rounded() == n.doubleValue
        case "string": return value is String
        case "array": return value is [Any]
        case "object": return value is [String: Any]
        default: return false
        }
    }

    private static func equal(_ a: Any, _ b: Any) -> Bool {
        if a is NSNull || b is NSNull { return a is NSNull && b is NSNull }
        if let a = a as? String, let b = b as? String { return a == b }
        if let a = a as? NSNumber, let b = b as? NSNumber { return a == b }
        return false
    }

    private static func describe(_ value: Any) -> String {
        if value is NSNull { return "null" }
        return String(describing: value)
    }
}
