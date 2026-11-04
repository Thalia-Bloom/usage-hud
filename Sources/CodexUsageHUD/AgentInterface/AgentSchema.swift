import Foundation

/// JSON Schema (2020-12) for AgentSummary schemaVersion 1 and the shapes
/// built from it. Used as MCP `outputSchema`, printed by `schema`, and
/// checked against real encoder output in AgentSummaryTests, so the
/// documented contract cannot drift from what the binary emits.
enum AgentSchema {
    static let paceValues = ["on_pace", "running_hot", "room", "almost_spent", "spent", "unknown"]
    static let modeValues = ["GO", "WATCH", "STOP", "CHECK"]
    static let confidenceValues = ["official", "measured", "estimated", "unknown"]
    static let windowValues = ["5h", "week", "day"]
    static let windowStateValues = ["live", "expired", "unknown", "reset_passed"]

    private static func string(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func nullableString(_ description: String) -> [String: Any] {
        ["type": ["string", "null"], "description": description]
    }

    private static func nullableEnum(_ values: [String], _ description: String) -> [String: Any] {
        ["type": ["string", "null"], "enum": (values as [Any]) + [NSNull()], "description": description]
    }

    private static func object(_ properties: [String: Any], description: String? = nil) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "properties": properties,
            "required": properties.keys.sorted(),
            "additionalProperties": false,
        ]
        if let description { schema["description"] = description }
        return schema
    }

    private static let percent: [String: Any] = ["type": "number", "minimum": 0, "description": "Percent of the window used (0-100)."]

    static var window: [String: Any] {
        object([
            "window": ["type": "string", "enum": windowValues, "description": "5h, week, or day."],
            "scope": nullableString("Model the window is limited to (\"Fable\"), or null for the whole plan."),
            "usedPercent": ["type": ["number", "null"], "minimum": 0, "description": "Percent used; null when the window expired or is unknown."],
            "resetsAt": nullableString("ISO 8601 time the window resets."),
            "resetsIn": nullableString("Time until reset, e.g. \"2h 10m\"."),
            "pace": ["type": "string", "enum": paceValues],
            "state": ["type": "string", "enum": windowStateValues],
        ])
    }

    static var lane: [String: Any] {
        object([
            "provider": string("Provider id: claude, codex, gemini, grok, or local."),
            "name": string("Display name."),
            "window": nullableEnum(windowValues, "The window this lane is headlined by."),
            "usedPercent": ["type": ["number", "null"], "minimum": 0, "description": "Percent of the headline window used; null when unknown."],
            "resetsAt": nullableString("ISO 8601 reset time of the headline window."),
            "resetsIn": nullableString("Time until that reset, e.g. \"4d 2h\"."),
            "pace": ["type": "string", "enum": paceValues, "description": "Spend against the clock: running_hot means it runs out before reset at this pace."],
            "status": string("The panel's own words, e.g. RUNNING HOT, 5H TIGHT, IDLE."),
            "forecastEmptyAt": nullableString("ISO 8601 time the window empties at this pace; set when running hot."),
            "confidence": ["type": "string", "enum": confidenceValues],
            "source": string("Where the number came from, e.g. \"official API\", \"statusline event\"."),
            "readingAgeSeconds": ["type": ["integer", "null"], "minimum": 0, "description": "Age of the reading in seconds."],
            "readingAge": nullableString("Age of the reading, e.g. \"3m\"."),
            "stale": ["type": "boolean", "description": "True when the reading is over 30 minutes old or missing."],
            "note": nullableString("One plain sentence when something needs explaining."),
            "windows": ["type": "array", "items": window, "description": "Every window this lane reports."],
        ])
    }

    static var verdict: [String: Any] {
        object([
            "mode": ["type": "string", "enum": modeValues, "description": "GO, WATCH, STOP, or CHECK (reading too old to trust)."],
            "lane": nullableString("Provider id the verdict is about."),
            "laneName": nullableString("Display name of that lane."),
            "sentence": string("One sentence for the user."),
        ])
    }

    static var room: [String: Any] {
        object([
            "lane": string("Provider id."),
            "laneName": string("Display name."),
            "window": nullableEnum(windowValues, "Headline window."),
            "usedPercent": percent,
            "pace": ["type": "string", "enum": paceValues],
            "resetsAt": nullableString("ISO 8601 reset time."),
            "resetsIn": nullableString("Time until reset."),
        ])
    }

    private static func nullable(_ schema: [String: Any]) -> [String: Any] {
        ["anyOf": [schema, ["type": "null"]]]
    }

    /// AgentSummary (`status --json`, MCP `usage_status`).
    static var summary: [String: Any] {
        var schema = object([
            "schemaVersion": ["type": "integer", "const": AgentSummary.currentSchemaVersion],
            "generatedAt": string("ISO 8601 time this summary was built."),
            "app": object(["name": string("App name."), "version": string("App version.")]),
            "verdict": verdict,
            "roomNow": nullable(room),
            "lanes": ["type": "array", "items": lane],
        ], description: "Usage HUD agent summary, schemaVersion 1.")
        schema["$schema"] = "https://json-schema.org/draft/2020-12/schema"
        schema["title"] = "UsageHUDAgentSummary"
        return schema
    }

    /// AgentRoomAdvice (`room --json`, MCP `which_plan_has_room`).
    static var roomAdvice: [String: Any] {
        object([
            "schemaVersion": ["type": "integer", "const": AgentSummary.currentSchemaVersion],
            "generatedAt": string("ISO 8601 time this answer was built."),
            "verdict": verdict,
            "roomNow": nullable(room),
            "advice": string("One sentence of advice."),
            "usable": ["type": "array", "items": room, "description": "Lanes with a fresh reading that are not spent, least used first."],
        ], description: "Which plan has room right now.")
    }

    /// MCP `lane_detail` result: `{ "lane": Lane }`.
    static var laneDetail: [String: Any] {
        object(["lane": lane], description: "One plan in detail.")
    }
}
